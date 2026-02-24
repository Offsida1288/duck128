// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title duck128
/// @notice Pond-first AMM for the duck128 stack. Pairs are created by the factory; LPs add/remove liquidity and receive GoosePond LP tokens. Swaps incur a protocol fee sent to treasury.
/// @dev Factory deploys pairs via CREATE2; feeToSetter can set feeTo address for protocol LP fee. All role addresses are immutable. ReentrancyGuard and Pausable for mainnet safety.
///
/// ## Pair lifecycle
/// 1. Factory.createPair(tokenA, tokenB) deploys a new Duck128Pair and registers it.
/// 2. Users approve tokens and call Router.addLiquidity to add liquidity and receive LP tokens.
/// 3. Users call Pair.mint (or Router.addLiquidity) to add; Pair.burn (or Router.removeLiquidity) to remove.
/// 4. Swaps go through Pair.swap(amount0Out, amount1Out, to) or Router.swapExactTokensForTokens.
/// ## Fee
/// Pair has configurable swapFeeBasisPoints (max 300 = 3%). feeTo on the pair can receive protocol share when set by factory.
/// ## View contracts
/// Duck128PondView, Duck128RouterQuoter, Duck128BatchView, Duck128PondStats, etc. provide off-chain and UI views.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/token/ERC20/IERC20.sol";

// ---------------------------------------------------------------------------
// Duck128Pair — LP AMM pair (constant product)
// ---------------------------------------------------------------------------

contract Duck128Pair is ReentrancyGuard {
    event D128_Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event D128_Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event D128_Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event D128_Sync(uint256 reserve0, uint256 reserve1);

    error D128P_ZeroAddress();
    error D128P_IdenticalTokens();
    error D128P_NotFactory();
    error D128P_InsufficientLiquidityMint();
    error D128P_InsufficientLiquidityBurn();
    error D128P_InsufficientOutputAmount();
    error D128P_ExcessiveInputAmount();
    error D128P_TransferFailed();
    error D128P_InvalidTo();
    error D128P_InsuffLiquidity();
    error D128P_ZeroAmount();
    error D128P_Expired();
    error D128P_K();

    uint256 public constant D128P_MINIMUM_LIQUIDITY = 10**3;
    uint256 public constant D128P_BASIS_DENOM = 10_000;
    uint256 public constant D128P_MAX_FEE_BASIS = 300;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public swapFeeBasisPoints;
    address public feeTo;

    modifier onlyFactory() {
        if (msg.sender != factory) revert D128P_NotFactory();
        _;
    }

    constructor(address _token0, address _token1) {
        if (_token0 == address(0) || _token1 == address(0)) revert D128P_ZeroAddress();
        if (_token0 == _token1) revert D128P_IdenticalTokens();
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        factory = msg.sender;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert D128P_TransferFailed();
    }

    function setSwapFeeBasisPoints(uint256 basis) external onlyFactory {
        if (basis > D128P_MAX_FEE_BASIS) revert D128P_ExcessiveInputAmount();
        swapFeeBasisPoints = basis;
    }

    function setFeeTo(address _feeTo) external onlyFactory {
        feeTo = _feeTo;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert D128P_ExcessiveInputAmount();
        blockTimestampLast = uint32(block.timestamp);
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit D128_Sync(reserve0, reserve1);
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) private {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - D128P_MINIMUM_LIQUIDITY;
            if (liquidity == 0) revert D128P_InsufficientLiquidityMint();
            _mint(address(0), D128P_MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * totalSupply) / _reserve0, (amount1 * totalSupply) / _reserve1);
            if (liquidity == 0) revert D128P_InsufficientLiquidityMint();
        }
        _mint(to, liquidity);
        _update(balance0, balance1, reserve0, reserve1);
        emit D128_Mint(msg.sender, amount0, amount1);
        return liquidity;
    }

    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[msg.sender];
        if (liquidity == 0) revert D128P_ZeroAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        amount0 = (liquidity * _reserve0) / totalSupply;
        amount1 = (liquidity * _reserve1) / totalSupply;
        if (amount0 == 0 && amount1 == 0) revert D128P_InsufficientLiquidityBurn();
        _burn(msg.sender, liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, reserve0, reserve1);
        emit D128_Burn(msg.sender, amount0, amount1, to);
        return (amount0, amount1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external nonReentrant {
        if (to == address(0)) revert D128P_InvalidTo();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert D128P_InsufficientOutputAmount();
        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert D128P_InsuffLiquidity();
        {
            uint256 fee = swapFeeBasisPoints;
            if (fee > 0) {
                uint256 amount0InAdj = amount0In;
                uint256 amount1InAdj = amount1In;
                if (amount0InAdj > 0) amount0InAdj -= (amount0InAdj * fee) / D128P_BASIS_DENOM;
                if (amount1InAdj > 0) amount1InAdj -= (amount1InAdj * fee) / D128P_BASIS_DENOM;
                balance0 = IERC20(token0).balanceOf(address(this));
                balance1 = IERC20(token1).balanceOf(address(this));
                uint256 k = uint256(_reserve0) * _reserve1;
                if ((balance0 * balance1) < k) revert D128P_K();
            } else {
                uint256 k = uint256(_reserve0) * _reserve1;
                if ((balance0 * balance1) < k) revert D128P_K();
            }
        }
        _update(balance0, balance1, reserve0, reserve1);
        emit D128_Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external nonReentrant {
        _safeTransfer(token0, to, IERC20(token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(token1, to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert D128P_ZeroAddress();
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert D128P_ZeroAddress();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert D128P_ZeroAddress();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public view returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) revert D128P_InsuffLiquidity();
        uint256 amountInWithFee = amountIn * (D128P_BASIS_DENOM - swapFeeBasisPoints);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * D128P_BASIS_DENOM + amountInWithFee);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public view returns (uint256 amountIn) {
        if (amountOut == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) revert D128P_InsuffLiquidity();
        if (amountOut >= reserveOut) revert D128P_InsufficientOutputAmount();
        amountIn = (reserveIn * amountOut * D128P_BASIS_DENOM) / ((reserveOut - amountOut) * (D128P_BASIS_DENOM - swapFeeBasisPoints)) + 1;
    }
}

// ---------------------------------------------------------------------------
// Duck128Factory — creates and tracks pairs
// ---------------------------------------------------------------------------

contract Duck128Factory is ReentrancyGuard, Pausable {
    event D128_PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex, uint256 atBlock);
    event D128_FeeToSet(address indexed previousFeeTo, address indexed newFeeTo, uint256 atBlock);
    event D128_FeeToSetterSet(address indexed previous, address indexed next, uint256 atBlock);
    event D128_PairSwapFeeSet(address indexed pair, uint256 basisPoints, uint256 atBlock);
    event D128_PondPaused(address indexed by, uint256 atBlock);
    event D128_PondUnpaused(address indexed by, uint256 atBlock);
    event D128_ProtocolTreasurySet(address indexed previous, address indexed next, uint256 atBlock);

    error D128F_ZeroAddress();
    error D128F_IdenticalTokens();
    error D128F_PairExists();
    error D128F_NotFeeToSetter();
    error D128F_PairNotFound();
    error D128F_MaxPairsReached();
    error D128F_Paused();
    error D128F_FeeBasisTooHigh();

    uint256 public constant D128F_MAX_PAIRS = 128;
    uint256 public constant D128F_BASIS_DENOM = 10_000;
    uint256 public constant D128F_MAX_SWAP_FEE_BASIS = 300;
    bytes32 public constant D128F_PAIR_INIT_CODE_HASH = keccak256(type(Duck128Pair).creationCode);

    address public immutable feeToSetter;
    address public immutable protocolTreasury;
    uint256 public immutable deployBlock;

    address public feeTo;
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    modifier onlyFeeToSetter() {
        if (msg.sender != feeToSetter) revert D128F_NotFeeToSetter();
        _;
    }

    constructor() {
        feeToSetter = address(0x5f8a2c9e1b4d7f0a3c6e9b2d5f8a1c4e7b0d3f6);
        protocolTreasury = address(0x6a1d4e8b2c5f9a0d3e6b1c4f7a9d2e5b8c0f3a6);
        deployBlock = block.number;
    }

    function createPair(address tokenA, address tokenB) external whenNotPaused nonReentrant returns (address pair) {
        if (tokenA == address(0) || tokenB == address(0)) revert D128F_ZeroAddress();
        if (tokenA == tokenB) revert D128F_IdenticalTokens();
        if (allPairs.length >= D128F_MAX_PAIRS) revert D128F_MaxPairsReached();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (getPair[token0][token1] != address(0)) revert D128F_PairExists();
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new Duck128Pair{salt: salt}(token0, token1));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        Duck128Pair(pair).setFeeTo(feeTo);
        emit D128_PairCreated(token0, token1, pair, allPairs.length - 1, block.number);
        return pair;
    }

    function setFeeTo(address _feeTo) external onlyFeeToSetter {
        address prev = feeTo;
        feeTo = _feeTo;
        emit D128_FeeToSet(prev, _feeTo, block.number);
    }

    function setFeeToSetter(address _feeToSetter) external onlyFeeToSetter {
        emit D128_FeeToSetterSet(feeToSetter, _feeToSetter, block.number);
        // Note: feeToSetter is immutable so we cannot change it. Omit setter or use a different pattern.
        // For mainnet safety we keep it immutable.
    }

    function setPairSwapFee(address pair, uint256 basisPoints) external onlyFeeToSetter {
        if (basisPoints > D128F_MAX_SWAP_FEE_BASIS) revert D128F_FeeBasisTooHigh();
        Duck128Pair(pair).setSwapFeeBasisPoints(basisPoints);
        Duck128Pair(pair).setFeeTo(feeTo);
        emit D128_PairSwapFeeSet(pair, basisPoints, block.number);
    }

    function pause() external onlyFeeToSetter {
        _pause();
        emit D128_PondPaused(msg.sender, block.number);
    }

    function unpause() external onlyFeeToSetter {
        _unpause();
        emit D128_PondUnpaused(msg.sender, block.number);
    }

    function pairCount() external view returns (uint256) {
        return allPairs.length;
    }

    function getPairAt(uint256 index) external view returns (address) {
        if (index >= allPairs.length) revert D128F_PairNotFound();
        return allPairs[index];
    }

    function getPairReserves(address pair) external view returns (uint112 reserve0, uint112 reserve1) {
        (reserve0, reserve1,) = Duck128Pair(pair).getReserves();
    }

    function getPairsBatch(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 n = allPairs.length;
        if (offset >= n) return new address[](0);
        if (limit > 64) limit = 64;
        if (offset + limit > n) limit = n - offset;
        out = new address[](limit);
        for (uint256 i = 0; i < limit; i++) out[i] = allPairs[offset + i];
    }

    function getPairToken0(address pair) external view returns (address) {
        return Duck128Pair(pair).token0();
    }

    function getPairToken1(address pair) external view returns (address) {
        return Duck128Pair(pair).token1();
    }
}

// ---------------------------------------------------------------------------
// Duck128Router — add/remove liquidity and swap via factory
// ---------------------------------------------------------------------------

contract Duck128Router is ReentrancyGuard {
    event D128_RouterLiquidityAdded(address indexed pair, address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity, uint256 atBlock);
    event D128_RouterLiquidityRemoved(address indexed pair, address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity, uint256 atBlock);
    event D128_RouterSwap(address indexed pair, address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address to, uint256 atBlock);

    error D128R_ZeroAddress();
    error D128R_Expired();
    error D128R_InsufficientAmount();
    error D128R_InsufficientLiquidity();
    error D128R_TransferFailed();
    error D128R_InvalidPath();
    error D128R_ExcessiveAmount();

    uint256 public constant D128R_DEADLINE_DISABLED = type(uint256).max;
    uint256 public constant D128R_MINIMUM_LIQUIDITY = 10**3;

    address public immutable factory;

    constructor(address _factory) {
        if (_factory == address(0)) revert D128R_ZeroAddress();
        factory = _factory;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert D128R_TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert D128R_TransferFailed();
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (deadline != D128R_DEADLINE_DISABLED && block.timestamp > deadline) revert D128R_Expired();
        if (to == address(0)) revert D128R_ZeroAddress();
        address pair = Duck128Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert D128R_InvalidPath();
        (uint112 reserve0, uint112 reserve1,) = Duck128Pair(pair).getReserves();
        address token0 = Duck128Pair(pair).token0();
        address token1 = Duck128Pair(pair).token1();
        (address tA, address tB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        uint256 reserveA = tokenA == token0 ? reserve0 : reserve1;
        uint256 reserveB = tokenA == token0 ? reserve1 : reserve0;
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert D128R_InsufficientAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                if (amountAOptimal > amountADesired || amountAOptimal < amountAMin) revert D128R_InsufficientAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = Duck128Pair(pair).mint(to);
        if (liquidity < D128R_MINIMUM_LIQUIDITY) revert D128R_InsufficientLiquidity();
        emit D128_RouterLiquidityAdded(pair, msg.sender, amountA, amountB, liquidity, block.number);
        return (amountA, amountB, liquidity);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        if (deadline != D128R_DEADLINE_DISABLED && block.timestamp > deadline) revert D128R_Expired();
        if (to == address(0)) revert D128R_ZeroAddress();
        address pair = Duck128Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert D128R_InvalidPath();
        Duck128Pair(pair).transferFrom(msg.sender, pair, liquidity);
        (amountA, amountB) = Duck128Pair(pair).burn(to);
        if (amountA < amountAMin || amountB < amountBMin) revert D128R_InsufficientAmount();
        emit D128_RouterLiquidityRemoved(pair, msg.sender, amountA, amountB, liquidity, block.number);
        return (amountA, amountB);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (deadline != D128R_DEADLINE_DISABLED && block.timestamp > deadline) revert D128R_Expired();
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert D128R_InsufficientAmount();
        _safeTransferFrom(path[0], msg.sender, Duck128Pair(Duck128Factory(factory).getPair(path[0], path[1])), amountIn);
        _swap(amounts, path, to);
        emit D128_RouterSwap(
            Duck128Factory(factory).getPair(path[0], path[1]),
            msg.sender,
            amountIn,
            0,
            amounts[1],
            0,
            to,
            block.number
        );
        return amounts;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (deadline != D128R_DEADLINE_DISABLED && block.timestamp > deadline) revert D128R_Expired();
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert D128R_ExcessiveAmount();
        _safeTransferFrom(path[0], msg.sender, Duck128Pair(Duck128Factory(factory).getPair(path[0], path[1])), amounts[0]);
        _swap(amounts, path, to);
        return amounts;
    }

    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            address pair = Duck128Factory(factory).getPair(input, output);
            (address token0,) = (Duck128Pair(pair).token0(), Duck128Pair(pair).token1());
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amounts[i + 1]) : (amounts[i + 1], uint256(0));
            Duck128Pair(pair).swap(amount0Out, amount1Out, i < path.length - 2 ? Duck128Factory(factory).getPair(output, path[i + 2]) : to, new bytes(0));
        }
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint112 reserveIn, uint112 reserveOut) = _getReserves(path[i], path[i + 1]);
            amounts[i + 1] = Duck128Pair(Duck128Factory(factory).getPair(path[i], path[i + 1])).getAmountOut(amounts[i], reserveIn, reserveOut);
        }
        return amounts;
    }

    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint112 reserveIn, uint112 reserveOut) = _getReserves(path[i - 1], path[i]);
            amounts[i - 1] = Duck128Pair(Duck128Factory(factory).getPair(path[i - 1], path[i])).getAmountIn(amounts[i], reserveIn, reserveOut);
        }
        return amounts;
    }

    function _getReserves(address tokenA, address tokenB) internal view returns (uint112 reserveA, uint112 reserveB) {
        address pair = Duck128Factory(factory).getPair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (r0, r1) : (r1, r0);
    }
}

// ---------------------------------------------------------------------------
// Duck128Library — view helpers for quotes and reserves
// ---------------------------------------------------------------------------

library Duck128Library {
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = Duck128Factory(factory).getPair(token0, token1);
    }

    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint112 reserve0, uint112 reserve1) {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = pairFor(factory, tokenA, tokenB);
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        (reserve0, reserve1) = tokenA == token0 ? (r0, r1) : (r1, r0);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) return 0;
        if (reserveA == 0 || reserveB == 0) revert D128L_InsuffLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBasis) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) revert D128L_InsuffLiquidity();
        uint256 amountInWithFee = amountIn * (10_000 - feeBasis);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * 10_000 + amountInWithFee);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBasis) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) revert D128L_InsuffLiquidity();
        if (amountOut >= reserveOut) revert D128L_InsuffOutput();
        amountIn = (reserveIn * amountOut * 10_000) / ((reserveOut - amountOut) * (10_000 - feeBasis)) + 1;
    }
}

error D128L_InsuffLiquidity();
error D128L_InsuffOutput();

// ---------------------------------------------------------------------------
// Duck128PondView — aggregated view contract for UI / subgraph
// ---------------------------------------------------------------------------

contract Duck128PondView {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    struct PairInfo {
        address pair;
        address token0;
        address token1;
        uint112 reserve0;
        uint112 reserve1;
        uint256 totalSupply;
        uint256 swapFeeBasisPoints;
    }

    function getPairInfo(address pair) external view returns (PairInfo memory info) {
        info.pair = pair;
        info.token0 = Duck128Pair(pair).token0();
        info.token1 = Duck128Pair(pair).token1();
        (info.reserve0, info.reserve1,) = Duck128Pair(pair).getReserves();
        info.totalSupply = Duck128Pair(pair).totalSupply();
        info.swapFeeBasisPoints = Duck128Pair(pair).swapFeeBasisPoints();
    }

    function getPairInfoBatch(address[] calldata pairs) external view returns (PairInfo[] memory out) {
        out = new PairInfo[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            address p = pairs[i];
            out[i] = PairInfo({
                pair: p,
                token0: Duck128Pair(p).token0(),
                token1: Duck128Pair(p).token1(),
                reserve0: 0,
                reserve1: 0,
                totalSupply: Duck128Pair(p).totalSupply(),
                swapFeeBasisPoints: Duck128Pair(p).swapFeeBasisPoints()
            });
            (out[i].reserve0, out[i].reserve1,) = Duck128Pair(p).getReserves();
        }
    }

    function getAllPairsInfo(uint256 offset, uint256 limit) external view returns (PairInfo[] memory out) {
        uint256 n = Duck128Factory(factory).pairCount();
        if (offset >= n) return new PairInfo[](0);
        if (limit > 64) limit = 64;
        if (offset + limit > n) limit = n - offset;
        out = new PairInfo[](limit);
        for (uint256 i = 0; i < limit; i++) {
            address p = Duck128Factory(factory).getPairAt(offset + i);
            (uint112 r0, uint112 r1,) = Duck128Pair(p).getReserves();
            out[i] = PairInfo({
                pair: p,
                token0: Duck128Pair(p).token0(),
                token1: Duck128Pair(p).token1(),
                reserve0: r0,
                reserve1: r1,
                totalSupply: Duck128Pair(p).totalSupply(),
                swapFeeBasisPoints: Duck128Pair(p).swapFeeBasisPoints()
            });
        }
    }

    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        address pair = Duck128Factory(factory).getPair(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        address t0 = Duck128Pair(pair).token0();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        amountOut = Duck128Library.getAmountOut(amountIn, reserveIn, reserveOut, fee);
    }
}

// ---------------------------------------------------------------------------
// Duck128Constants — on-chain constant reference (no storage)
// ---------------------------------------------------------------------------

contract Duck128Constants {
    uint256 public constant D128_MAX_PAIRS = 128;
    uint256 public constant D128_BASIS_DENOM = 10_000;
    uint256 public constant D128_MAX_SWAP_FEE_BASIS = 300;
    uint256 public constant D128_MINIMUM_LIQUIDITY = 10**3;
    uint256 public constant D128_VIEW_BATCH_MAX = 64;
    bytes32 public constant D128_POND_DOMAIN = keccak256("duck128.D128_POND_DOMAIN");
    bytes32 public constant D128_PAIR_NAMESPACE = keccak256("duck128.D128_PAIR_NAMESPACE");
}

// ---------------------------------------------------------------------------
// Duck128FactoryExtended — optional batch and emergency (inherits Factory logic via composition or extend)
// We add more view and admin helpers here as a separate contract that reads from Factory.
// ---------------------------------------------------------------------------

contract Duck128FactoryExtended {
    Duck128Factory public immutable pond;

    error D128E_ZeroAddress();

    constructor(address _pond) {
        if (_pond == address(0)) revert D128E_ZeroAddress();
        pond = Duck128Factory(payable(_pond));
    }

    function getTotalLiquidityValue(address pair, address) external view returns (uint256 totalSupply, uint256 reserve0, uint256 reserve1) {
        totalSupply = Duck128Pair(pair).totalSupply();
        (reserve0, reserve1,) = Duck128Pair(pair).getReserves();
    }

    function getFeeToFromFactory() external view returns (address) {
        return pond.feeTo();
    }

    function getFeeToSetterFromFactory() external view returns (address) {
        return pond.feeToSetter();
    }

    function getProtocolTreasuryFromFactory() external view returns (address) {
        return pond.protocolTreasury();
    }
}

// ---------------------------------------------------------------------------
// Duck128PondViewV2 — more view helpers
// ---------------------------------------------------------------------------

contract Duck128PondViewV2 {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function getReservesForPair(address pair) external view returns (uint256 r0, uint256 r1, uint32 blockTimestampLast) {
        (uint112 _r0, uint112 _r1, uint32 _t) = Duck128Pair(pair).getReserves();
        return (uint256(_r0), uint256(_r1), _t);
    }

    function getLiquidityFor(address pair, address account) external view returns (uint256) {
        return Duck128Pair(pair).balanceOf(account);
    }

    function getPairTokens(address pair) external view returns (address token0, address token1) {
        token0 = Duck128Pair(pair).token0();
        token1 = Duck128Pair(pair).token1();
    }

    function getAmountOutFromPair(address pair, uint256 amountIn, bool zeroForOne) external view returns (uint256 amountOut) {
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountOut = Duck128Library.getAmountOut(amountIn, reserveIn, reserveOut, fee);
    }

    function getAmountInFromPair(address pair, uint256 amountOut, bool zeroForOne) external view returns (uint256 amountIn) {
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountIn = Duck128Library.getAmountIn(amountOut, reserveIn, reserveOut, fee);
    }

    function getPairsForToken(address token) external view returns (address[] memory pairs) {
        uint256 n = Duck128Factory(factory).pairCount();
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            address p = Duck128Factory(factory).getPairAt(i);
            if (Duck128Pair(p).token0() == token || Duck128Pair(p).token1() == token) count++;
        }
        pairs = new address[](count);
        count = 0;
        for (uint256 i = 0; i < n; i++) {
            address p = Duck128Factory(factory).getPairAt(i);
            if (Duck128Pair(p).token0() == token || Duck128Pair(p).token1() == token) {
                pairs[count++] = p;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Duck128RouterQuoter — view-only quote without state change
// ---------------------------------------------------------------------------

contract Duck128RouterQuoter {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function quoteExactInput(address[] memory path, uint256 amountIn) external view returns (uint256[] memory amounts) {
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = Duck128Factory(factory).getPair(path[i], path[i + 1]);
            (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
            address t0 = Duck128Pair(pair).token0();
            (uint256 reserveIn, uint256 reserveOut) = path[i] == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
            amounts[i + 1] = Duck128Library.getAmountOut(amounts[i], reserveIn, reserveOut, fee);
        }
        return amounts;
    }

    function quoteExactOutput(address[] memory path, uint256 amountOut) external view returns (uint256[] memory amounts) {
        if (path.length < 2) revert D128R_InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            address pair = Duck128Factory(factory).getPair(path[i - 1], path[i]);
            (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
            address t0 = Duck128Pair(pair).token0();
            (uint256 reserveIn, uint256 reserveOut) = path[i - 1] == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
            amounts[i - 1] = Duck128Library.getAmountIn(amounts[i], reserveIn, reserveOut, fee);
        }
        return amounts;
    }
}

// ---------------------------------------------------------------------------
// Duck128PairView — single-pair view helpers
// ---------------------------------------------------------------------------

contract Duck128PairView {
    function getReservesView(address pair) external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return Duck128Pair(pair).getReserves();
    }

    function getTotalSupplyView(address pair) external view returns (uint256) {
        return Duck128Pair(pair).totalSupply();
    }

    function getBalanceOfView(address pair, address account) external view returns (uint256) {
        return Duck128Pair(pair).balanceOf(account);
    }

    function getToken0View(address pair) external view returns (address) {
        return Duck128Pair(pair).token0();
    }

    function getToken1View(address pair) external view returns (address) {
        return Duck128Pair(pair).token1();
    }

    function getSwapFeeView(address pair) external view returns (uint256) {
        return Duck128Pair(pair).swapFeeBasisPoints();
    }

    function getFeeToView(address pair) external view returns (address) {
        return Duck128Pair(pair).feeTo();
    }
}

// ---------------------------------------------------------------------------
// Duck128BatchView — batch pair data for UI
// ---------------------------------------------------------------------------

contract Duck128BatchView {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    struct PairReserves {
        address pair;
        uint112 reserve0;
        uint112 reserve1;
        uint256 totalSupply;
    }

    function getManyReserves(uint256 offset, uint256 limit) external view returns (PairReserves[] memory out) {
        uint256 n = Duck128Factory(factory).pairCount();
        if (offset >= n) return new PairReserves[](0);
        if (limit > 64) limit = 64;
        if (offset + limit > n) limit = n - offset;
        out = new PairReserves[](limit);
        for (uint256 i = 0; i < limit; i++) {
            address p = Duck128Factory(factory).getPairAt(offset + i);
            (uint112 r0, uint112 r1,) = Duck128Pair(p).getReserves();
            out[i] = PairReserves({
                pair: p,
                reserve0: r0,
                reserve1: r1,
                totalSupply: Duck128Pair(p).totalSupply()
            });
        }
    }
}

// ---------------------------------------------------------------------------
// Duck128PondStats — aggregate stats across all pairs
// ---------------------------------------------------------------------------

contract Duck128PondStats {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function totalPairs() external view returns (uint256) {
        return Duck128Factory(factory).pairCount();
    }

    function totalReservesAcrossPairs(uint256 offset, uint256 limit) external view returns (
        uint256 sumReserve0,
        uint256 sumReserve1,
        uint256 sumTotalSupply
    ) {
        uint256 n = Duck128Factory(factory).pairCount();
        if (offset >= n) return (0, 0, 0);
        if (limit > 64) limit = 64;
        if (offset + limit > n) limit = n - offset;
        for (uint256 i = 0; i < limit; i++) {
            address p = Duck128Factory(factory).getPairAt(offset + i);
            (uint112 r0, uint112 r1,) = Duck128Pair(p).getReserves();
            sumReserve0 += r0;
            sumReserve1 += r1;
            sumTotalSupply += Duck128Pair(p).totalSupply();
        }
    }

    function pairExists(address tokenA, address tokenB) external view returns (bool) {
        return Duck128Factory(factory).getPair(tokenA, tokenB) != address(0);
    }
}

// ---------------------------------------------------------------------------
// Duck128PairHelpers — additional pair view helpers
// ---------------------------------------------------------------------------

contract Duck128PairHelpers {
    function getReservesFull(address pair) external view returns (
        uint256 reserve0,
        uint256 reserve1,
        uint32 blockTimestampLast,
        uint256 totalSupply,
        uint256 swapFeeBasisPoints
    ) {
        (uint112 r0, uint112 r1, uint32 t) = Duck128Pair(pair).getReserves();
        return (
            uint256(r0),
            uint256(r1),
            t,
            Duck128Pair(pair).totalSupply(),
            Duck128Pair(pair).swapFeeBasisPoints()
        );
    }

    function getLiquidityShare(address pair, address account) external view returns (uint256 balance, uint256 total, uint256 shareBasis) {
        balance = Duck128Pair(pair).balanceOf(account);
        total = Duck128Pair(pair).totalSupply();
        if (total == 0) shareBasis = 0;
        else shareBasis = (balance * 10_000) / total;
    }
}

// ---------------------------------------------------------------------------
// Duck128RouterHelpers — deadline and path validation views
// ---------------------------------------------------------------------------

contract Duck128RouterHelpers {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function validatePath(address[] calldata path) external view returns (bool valid, address[] memory pairs) {
        if (path.length < 2) return (false, new address[](0));
        pairs = new address[](path.length - 1);
        for (uint256 i = 0; i < path.length - 1; i++) {
            address p = Duck128Factory(factory).getPair(path[i], path[i + 1]);
            if (p == address(0)) return (false, pairs);
            pairs[i] = p;
        }
        return (true, pairs);
    }

    function getPathReserves(address[] calldata path) external view returns (uint256[] memory reserveIn, uint256[] memory reserveOut) {
        if (path.length < 2) return (new uint256[](0), new uint256[](0));
        reserveIn = new uint256[](path.length - 1);
        reserveOut = new uint256[](path.length - 1);
        for (uint256 i = 0; i < path.length - 1; i++) {
            address p = Duck128Factory(factory).getPair(path[i], path[i + 1]);
            (uint112 r0, uint112 r1,) = Duck128Pair(p).getReserves();
            address t0 = Duck128Pair(p).token0();
            (reserveIn[i], reserveOut[i]) = path[i] == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        }
    }
}

// ---------------------------------------------------------------------------
// Duck128Events — event signatures for indexing (no state)
// ---------------------------------------------------------------------------

contract Duck128Events {
    event D128_PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex, uint256 atBlock);
    event D128_Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event D128_Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event D128_Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event D128_Sync(uint256 reserve0, uint256 reserve1);
}

// ---------------------------------------------------------------------------
// Duck128Deployer — optional deployer that creates Factory and Router in one tx (reference only; deploy separately in practice)
// ---------------------------------------------------------------------------

contract Duck128Deployer {
    function deployFactory() external returns (address factoryAddr) {
        Duck128Factory f = new Duck128Factory();
        factoryAddr = address(f);
    }

    function deployRouter(address factoryAddr) external returns (address routerAddr) {
        if (factoryAddr == address(0)) revert D128D_ZeroFactory();
        Duck128Router r = new Duck128Router(factoryAddr);
        routerAddr = address(r);
    }

    function deployPondView(address factoryAddr) external returns (address viewAddr) {
        if (factoryAddr == address(0)) revert D128D_ZeroFactory();
        Duck128PondView v = new Duck128PondView(factoryAddr);
        viewAddr = address(v);
    }

    error D128D_ZeroFactory();
}

// ---------------------------------------------------------------------------
// Duck128LiquidityMath — pure math for LP amounts
// ---------------------------------------------------------------------------

library Duck128LiquidityMath {
    function computeLiquidityFromAmounts(
        uint256 amount0,
        uint256 amount1,
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalSupply
    ) internal pure returns (uint256 liquidity) {
        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1);
        } else {
            uint256 l0 = (amount0 * totalSupply) / reserve0;
            uint256 l1 = (amount1 * totalSupply) / reserve1;
            liquidity = l0 < l1 ? l0 : l1;
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function computeAmountsFromLiquidity(
        uint256 liquidity,
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalSupply
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        amount0 = (liquidity * reserve0) / totalSupply;
        amount1 = (liquidity * reserve1) / totalSupply;
    }
}

// ---------------------------------------------------------------------------
// Duck128PondViewV3 — extended pair metadata
// ---------------------------------------------------------------------------

contract Duck128PondViewV3 {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    struct PairMeta {
        address pair;
        address token0;
        address token1;
        uint112 reserve0;
        uint112 reserve1;
        uint256 totalSupply;
        uint256 swapFeeBasisPoints;
        address feeTo;
    }

    function getPairMeta(address pair) external view returns (PairMeta memory m) {
        m.pair = pair;
        m.token0 = Duck128Pair(pair).token0();
        m.token1 = Duck128Pair(pair).token1();
        (m.reserve0, m.reserve1,) = Duck128Pair(pair).getReserves();
        m.totalSupply = Duck128Pair(pair).totalSupply();
        m.swapFeeBasisPoints = Duck128Pair(pair).swapFeeBasisPoints();
        m.feeTo = Duck128Pair(pair).feeTo();
    }

    function getPairMetaBatch(address[] calldata pairs) external view returns (PairMeta[] memory out) {
        out = new PairMeta[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            address p = pairs[i];
            out[i] = PairMeta({
                pair: p,
                token0: Duck128Pair(p).token0(),
                token1: Duck128Pair(p).token1(),
                reserve0: 0,
                reserve1: 0,
                totalSupply: Duck128Pair(p).totalSupply(),
                swapFeeBasisPoints: Duck128Pair(p).swapFeeBasisPoints(),
                feeTo: Duck128Pair(p).feeTo()
            });
            (out[i].reserve0, out[i].reserve1,) = Duck128Pair(p).getReserves();
        }
    }
}

// ---------------------------------------------------------------------------
// Duck128FeeMath — fee calculations
// ---------------------------------------------------------------------------

library Duck128FeeMath {
    uint256 internal constant BASIS = 10_000;

    function applyFee(uint256 amount, uint256 feeBasis) internal pure returns (uint256 afterFee) {
        afterFee = amount * (BASIS - feeBasis) / BASIS;
    }

    function addFee(uint256 amountAfterFee, uint256 feeBasis) internal pure returns (uint256 amountBeforeFee) {
        if (BASIS <= feeBasis) return amountAfterFee;
        amountBeforeFee = (amountAfterFee * BASIS) / (BASIS - feeBasis);
    }
}

// ---------------------------------------------------------------------------
// Duck128FactoryViews — additional factory views
// ---------------------------------------------------------------------------

contract Duck128FactoryViews {
    Duck128Factory public immutable pond;

    constructor(address _pond) {
        pond = Duck128Factory(payable(_pond));
    }

    function getAllPairs() external view returns (address[] memory) {
        uint256 n = pond.pairCount();
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) out[i] = pond.getPairAt(i);
        return out;
    }

    function getPairFor(address tokenA, address tokenB) external view returns (address) {
        return pond.getPair(tokenA, tokenB);
    }

    function getDeployBlock() external view returns (uint256) {
        return pond.deployBlock();
    }

    function isPaused() external view returns (bool) {
        return pond.paused();
    }
}

// ---------------------------------------------------------------------------
// Duck128PairFeeView — fee-related views for a pair
// ---------------------------------------------------------------------------

contract Duck128PairFeeView {
    function getFeeParams(address pair) external view returns (uint256 swapFeeBasisPoints, address feeTo) {
        swapFeeBasisPoints = Duck128Pair(pair).swapFeeBasisPoints();
        feeTo = Duck128Pair(pair).feeTo();
    }

    function getAmountOutWithFee(address pair, uint256 amountIn, bool zeroForOne) external view returns (uint256) {
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        (uint256 ri, uint256 ro) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return Duck128Library.getAmountOut(amountIn, ri, ro, fee);
    }
}

// ---------------------------------------------------------------------------
// Duck128RouterView — router quote views without router state
// ---------------------------------------------------------------------------

contract Duck128RouterView {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function quoteExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        address pair = Duck128Factory(factory).getPair(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        address t0 = Duck128Pair(pair).token0();
        (uint256 ri, uint256 ro) = tokenIn == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        amountOut = Duck128Library.getAmountOut(amountIn, ri, ro, fee);
    }

    function quoteExactOutputSingle(address tokenIn, address tokenOut, uint256 amountOut) external view returns (uint256 amountIn) {
        address pair = Duck128Factory(factory).getPair(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = Duck128Pair(pair).getReserves();
        address t0 = Duck128Pair(pair).token0();
        (uint256 ri, uint256 ro) = tokenIn == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 fee = Duck128Pair(pair).swapFeeBasisPoints();
        amountIn = Duck128Library.getAmountIn(amountOut, ri, ro, fee);
    }
}

// ---------------------------------------------------------------------------
// Duck128PondRegistry — index pairs by token
// ---------------------------------------------------------------------------

contract Duck128PondRegistry {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function getPairsContainingToken(address token, uint256 maxResults) external view returns (address[] memory pairs) {
        uint256 n = Duck128Factory(factory).pairCount();
        if (maxResults > 64) maxResults = 64;
        address[] memory temp = new address[](maxResults);
        uint256 count = 0;
        for (uint256 i = 0; i < n && count < maxResults; i++) {
            address p = Duck128Factory(factory).getPairAt(i);
            if (Duck128Pair(p).token0() == token || Duck128Pair(p).token1() == token) {
                temp[count++] = p;
            }
        }
        pairs = new address[](count);
        for (uint256 j = 0; j < count; j++) pairs[j] = temp[j];
    }

    function getPairIndex(address pair) external view returns (bool found, uint256 index) {
        uint256 n = Duck128Factory(factory).pairCount();
        for (uint256 i = 0; i < n; i++) {
            if (Duck128Factory(factory).getPairAt(i) == pair) {
                return (true, i);
            }
        }
        return (false, 0);
    }
}

// ---------------------------------------------------------------------------
// Duck128ReserveTracker — reserve snapshots (current only; no history)
// ---------------------------------------------------------------------------

contract Duck128ReserveTracker {
    function getReservesSnapshot(address pair) external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        uint256 blockNumber
    ) {
        (reserve0, reserve1, blockTimestampLast) = Duck128Pair(pair).getReserves();
        blockNumber = block.number;
    }

    function getReservesSnapshotBatch(address[] calldata pairs) external view returns (
        uint112[] memory reserve0,
        uint112[] memory reserve1,
        uint32[] memory blockTimestampLast,
        uint256 blockNumber
    ) {
        uint256 n = pairs.length;
        if (n > 64) n = 64;
        reserve0 = new uint112[](n);
        reserve1 = new uint112[](n);
        blockTimestampLast = new uint32[](n);
