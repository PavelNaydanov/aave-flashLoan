// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {IERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IFlashLoanReceiver.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingAdapter.sol";
import "./interfaces/IUniswapV2Router02.sol";

contract Liquidator is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    ILendingPool lendingPool;
    ILendingAdapter lendingAdapter;
    IUniswapV2Router02 router;

    IERC20 tokenA; // collateral token
    IERC20 tokenB; // debt token

    constructor(address _lendingPool, address _lendingAdapter, address _router) {
        lendingPool = ILendingPool(_lendingPool);
        lendingAdapter = ILendingAdapter(_lendingAdapter);
        router = IUniswapV2Router02(_router);

        tokenA = lendingAdapter.tokenA();
        tokenB = lendingAdapter.tokenB();
    }

    function liquidate(address borrower, uint256 repayAmount) external {
        address[] memory assets = new address[](1);
        assets[0] = address(tokenB);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = repayAmount;

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        bytes memory params = abi.encode(borrower, msg.sender);

        lendingPool.flashLoan(
            address(this),
            assets,
            amounts,
            modes,
            address(this),
            params,
            0
        );
    }

    function executeOperation(
        address[] calldata /** assets **/,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address /** initiator **/ ,
        bytes calldata params
    ) external returns (bool) {
        (address borrower, address recipient) = abi.decode(params, (address, address));
        uint256 repayAmount = amounts[0];

        // Approve the LendingPool contract allowance to *pull* the owed amount
        uint amountOwing = amounts[0] + premiums[0];
        tokenB.safeApprove(address(lendingPool), amountOwing);

        // liquidate loan, repay tokenB, seize tokenA
        tokenB.safeApprove(address(lendingAdapter), repayAmount);
        lendingAdapter.liquidate(borrower, repayAmount);

        // swap tokenA to exact amountOwing of tokenB
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        tokenA.safeApprove(address(router), tokenA.balanceOf(address(this)));
        router.swapTokensForExactTokens(
            amountOwing,
            tokenA.balanceOf(address(this)),
            path,
            address(this),
            block.timestamp
        );

        // transfer the rest of tokenA to the recipient
        tokenA.safeTransfer(recipient, tokenA.balanceOf(address(this)));

        return true;
    }
}