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

