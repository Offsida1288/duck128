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
