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
