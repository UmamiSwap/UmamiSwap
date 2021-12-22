//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/SwapRouter02.sol";
import "./interfaces/SwapFactory.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20VotesComp.sol";

abstract contract ERC20Fees is ERC20VotesComp, AccessControl {
    uint256 private constant MAX_FEE_PPM = 400_000;
    bytes32 public constant FEE_ROLE = keccak256("FEE_ROLE");

    // After saving what amount of tokens should the contract sell (also known as swapAndLiquify) 
    uint256 public sellBuffer;
    // This disables all non-standard functionality incase something goes wrong
    bool public safemode = false;
    // Used to detect when a transfer is being done by us
    SwapRouter02 public primaryRouter;
    address private routerWrappedNativeToken;
    bool private handlingFee = false;
    // Tracks the fees collected in this token
    uint256 public buyBackTokenAmount;
    uint256 public autoLpTokenAmount;
    uint256 public marketingTokenAmount;
    uint256 public devTokenAmount;
    // Tracks the fees collected in the Native coin
    uint256 public buyBackNativeAmount;
    uint256 public marketingNativeAmount;
    uint256 public devNativeAmount;
    address public devFeeWallet;
    address public marketingFeeWallet;
    // Used to track rewards
    uint256 public totalRewards;
    uint256 public tokensCollectingRewards;
    // The reward token that is being paid out
    address public rewardToken;
    mapping(address => bool) public excludedFromRewards;
    mapping(address => uint256) public lastCollectedAt;
    // Recipient of the autoLP
    address public lpRecipient = 0x92b8Ef4d716dfcD112b1E4a70bA8B33B54f02289;

    // Used to check what type a transaction is
    mapping(address => bool) public isPair;
    mapping(address => bool) public excludedFromFees;
    mapping(TransactionType => FeeSettings) public feeInfo;

    // Events
    event RewardCollected(address indexed user, address indexed token, uint256 amount);
    event RewardWaived(address indexed user, uint256 amount);
    event BuyBack(uint256 nativeAmount, uint256 tokensAmount);
    // Events emitted when token settings get changed
    event FeeUpdated(TransactionType transactionType, FeeSettings settings);
    event ExcludedFromFeesChange(address addr, bool status);
    event ExcludedFromRewardsChange(address addr, bool status);
    event SellBufferChanged(uint256 newAmount);
    event RewardTokenChanged(address toToken);
    event MarketingWalletChanged(address addr);
    event DevWalletChanged(address addr);
    event SafeModeChanged(bool status);
    event LpRecipientChanged(address addr);

    modifier disableFees() {
        handlingFee = true;
        _;
        handlingFee = false;
    }

    constructor(
        address _dex,
        address _marketingFeeWallet,
        address _devFeeWallet
    ) {
        // Set the team wallets
        devFeeWallet = _devFeeWallet;
        marketingFeeWallet = _marketingFeeWallet;

        // Exclude this contract from the fees (to prevent recursive fees)
        excludedFromFees[address(this)] = true;
        excludedFromRewards[address(this)] = true;
        excludedFromRewards[address(0)] = true;

        // Set the router and create the pair
        _changeRouter(_dex);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        // Some user may try to send tokens to themselves to collect the rewards
        // Since this is not supported by us we error so they don't pay the fee over the tx
        require(sender != recipient);

        // If safemode is enabled we disable all custom functionality
        if (safemode) {
            return super._transfer(sender, recipient, amount);
        }

        // Decide what type of transaction this is, that way we can use the corresponding fee
        TransactionType txType = getTransactionType(sender, recipient);
        FeeSettings memory txFee = feeInfo[txType];

        // If this txType requires a fee subtract and handle the fee
        // If handlingFee is true, the transfer is recursive
        if (
            !handlingFee &&
            txFee.totalFeePPM > 0 &&
            !excludedFromFees[sender] &&
            !excludedFromFees[recipient]
        ) {
            // Calc the fee amount
            uint256 feeAmount = (amount * txFee.totalFeePPM) / 1_000_000;
            // The tokens collected as fee do not earn any rewards
            tokensCollectingRewards -= feeAmount;
            // Transfer the fee to this contract
            super._transfer(sender, address(this), feeAmount);
            // Handle the fee
            _distributeFee(txFee.distribution, feeAmount);
            // Subtract the fee amount from the original amount
            amount -= feeAmount;

            // If balance goes over set limit we perform all the swaps and AutoLP
            if (
                txType != TransactionType.Buy &&
                buyBackTokenAmount +
                    autoLpTokenAmount /
                    2 +
                    marketingTokenAmount +
                    devTokenAmount >
                sellBuffer
            ) {
                _performSwap();
            }
        }

        // Check if the sender is excluded but the recipient is included (this means tokens become activated)
        if (excludedFromRewards[sender] && !excludedFromRewards[recipient]) {
            tokensCollectingRewards += amount;

            // Check if the sender is included but the recipient is excluded (this means tokens become deactivated)
        } else if (
            !excludedFromRewards[sender] && excludedFromRewards[recipient]
        ) {
            tokensCollectingRewards -= amount;
        }

        // Rewards are waived when the user transfers tokens
        // this makes it so bots do not get a part of the rewards
        _waiveRewards(sender);
        // We recalculate the recipient rewards so the reward amount stays the same
        // but it will increase at a higher speed from now on
        _recalcRewards(recipient, amount);

        // Perform the transfer
        super._transfer(sender, recipient, amount);
    }

    function getTransactionType(address sender, address recipient)
        public
        view
        returns (TransactionType)
    {
        // Check if the recipient is a pair
        // This would make it a sell (or LP Add)
        if (isPair[recipient]) {
            return TransactionType.Sell;
        }

        // Check if the sender is a pair
        // This would make it a buy (or LP remove)
        if (isPair[sender]) {
            return TransactionType.Buy;
        }

        // We default to Transfer
        return TransactionType.Transfer;
    }

    // Fee handling
    function _distributeFee(
        FeeDistributionSettings memory feeDistribution,
        uint256 amount
    ) internal {
        uint256 ppmLeft = 1_000_000;

        if (feeDistribution.buybackPPM > 0) {
            uint256 change = (amount * feeDistribution.buybackPPM) / ppmLeft;
            buyBackTokenAmount += change;
            amount -= change;
            ppmLeft -= feeDistribution.buybackPPM;
        }

        if (feeDistribution.autoLpPPM > 0) {
            uint256 change = (amount * feeDistribution.autoLpPPM) / ppmLeft;
            autoLpTokenAmount += change;
            amount -= change;
            ppmLeft -= feeDistribution.autoLpPPM;
        }

        if (feeDistribution.marketingPPM > 0) {
            uint256 change = (amount * feeDistribution.marketingPPM) / ppmLeft;
            marketingTokenAmount += change;
            amount -= change;
            ppmLeft -= feeDistribution.marketingPPM;
        }

        if (feeDistribution.rewardPPM > 0) {
            uint256 change = (amount * feeDistribution.rewardPPM) / ppmLeft;
            totalRewards += change;
            amount -= change;
            ppmLeft -= feeDistribution.rewardPPM;
        }

        require(feeDistribution.devPPM == ppmLeft);

        // To prevent dust we don't use the devPPM but the amount that is left
        devTokenAmount += amount;
    }

    function _performSwap() internal disableFees {
        // Perform all the swaps in 1 call to save on gas
        // We calculate what percentage the different fees are so we can split the end result
        uint256 amountToSwap = (autoLpTokenAmount / 2) + marketingTokenAmount + devTokenAmount + buyBackTokenAmount;
        uint256 ppmPerToken =  amountToSwap / 1_000_000;
        uint256 marketingPPM = marketingTokenAmount / ppmPerToken;
        uint256 devPPM = devTokenAmount / ppmPerToken;
        uint256 buyBackPPM = buyBackTokenAmount / ppmPerToken;

        // Perform the swap
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = routerWrappedNativeToken;

        primaryRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        // We do it this way so we catch all dust in the contract
        uint256 receivedAmount = address(this).balance - marketingNativeAmount - devNativeAmount - buyBackNativeAmount;
        marketingNativeAmount += receivedAmount * marketingPPM / 1_000_000;
        devNativeAmount += receivedAmount * devPPM / 1_000_000;
        buyBackNativeAmount += receivedAmount * buyBackPPM / 1_000_000;

        // We do it with subtraction to prevent rounding errors
        uint256 autoLpNativeAmount = address(this).balance - marketingNativeAmount - devNativeAmount - buyBackNativeAmount;

        if (autoLpNativeAmount > 100) {
            // Add the LP
            primaryRouter.addLiquidityETH{value: autoLpNativeAmount}(
                address(this),
                autoLpTokenAmount / 2,
                0,
                0,
                lpRecipient,
                block.timestamp
            );

            autoLpTokenAmount = 0;
        }

        // All the tokens are now sold, set as 0
        marketingTokenAmount = 0;
        devTokenAmount = 0;
        buyBackTokenAmount = 0;
    }

    function changeRouter(address newRouter) public onlyRole(FEE_ROLE) {
        _changeRouter(newRouter);
    }

    function _changeRouter(address newRouter) internal {
        SwapRouter02 router = SwapRouter02(newRouter);
        SwapFactory factory = SwapFactory(router.factory());

        // Check if a router was already set, if so set allowance to 0
        if (address(primaryRouter) != address(0)) {
            approve(address(primaryRouter), 0);
        }

        // Set the Wrapped native token to the one the primary dex is using
        routerWrappedNativeToken = router.WETH();

        // Get the pair if it already exists
        address pairAddress = factory.getPair(
            address(this),
            routerWrappedNativeToken
        );

        // Check if the pair exists, otherwise create the new pair
        if (pairAddress == address(0)) {
            pairAddress = factory.createPair(
                address(this),
                routerWrappedNativeToken
            );
        }

        // Register the pair
        isPair[pairAddress] = true;
        excludedFromRewards[pairAddress] = true;
        primaryRouter = router;

        // Approve the new router with our tokens
        _approve(address(this), newRouter, uint256(2**256 - 1));
    }

    function registerPair(address _router, address _otherToken)
        public
        onlyRole(FEE_ROLE)
    {
        SwapRouter02 router = SwapRouter02(_router);
        SwapFactory factory = SwapFactory(router.factory());

        // Get the pair if it already exists
        address pairAddress = factory.getPair(address(this), _otherToken);
        require(pairAddress != address(0)); // PAIR DOES NOT EXIST

        // If the pair has already collected some rewards we redistribute them
        _waiveRewards(pairAddress);

        // Register the pair
        isPair[pairAddress] = true;
        excludedFromRewards[pairAddress] = true;
    }

    function updateFee(TransactionType txType, FeeSettings calldata settings)
        external
        onlyRole(FEE_ROLE)
    {
        require(settings.totalFeePPM <= MAX_FEE_PPM); // MORE THAN MAX FEE
        require(
            settings.distribution.buybackPPM +
                settings.distribution.autoLpPPM +
                settings.distribution.marketingPPM +
                settings.distribution.rewardPPM +
                settings.distribution.devPPM ==
                1_000_000
        ); // NOT EXACTLY 1M

        // Emit event and update fee
        emit FeeUpdated(txType, settings);
        feeInfo[txType] = settings;
    }

    function _waiveRewards(address user) internal {
        uint256 rewards = outstandingRewards(user);
        totalRewards += rewards;
        lastCollectedAt[user] = totalRewards;

        emit RewardWaived(user, rewards);
    }

    function collectRewards() external {
        // Send the user his rewards
        _collectRewards(msg.sender);

        // If the user is the devWallet send the dev fee
        if (msg.sender == devFeeWallet) {
            uint256 fees = devNativeAmount;
            devNativeAmount = 0;
            (bool sent, ) = payable(msg.sender).call{value: fees}("");
            require(sent);
        }

        // If the user is the marketingWallet send the marketing fee
        if (msg.sender == marketingFeeWallet) {
            uint256 fees = marketingNativeAmount;
            marketingNativeAmount = 0;
            (bool sent, ) = payable(msg.sender).call{value: fees}("");
            require(sent);
        }
    }

    function _recalcRewards(address user, uint256 tokensAdded) internal {
        uint256 userBalance = balanceOf(user);
        uint256 rewards = outstandingRewards(user);

        // If no rewards have been collected the default of 0 is correct
        if (totalRewards == 0) {
            return;
        }

        // Calculate the percenatage this user owns of the supply
        uint256 newPPM = totalSupply() / (userBalance + tokensAdded);

        // We calculate what the new 'lastCollectedAt' should become to keep the same rewards for the user
        uint256 userRewardsWithoutRecalc = totalRewards * newPPM / 1_000_000;
        uint256 collectedAgo = rewards / userRewardsWithoutRecalc * totalRewards;
        lastCollectedAt[user] = totalRewards - collectedAgo;
    }

    function _collectRewards(address user) internal disableFees {
        uint256 rewards = outstandingRewards(user);
        if (rewards == 0) return;

        // Update the amount collected by the user
        lastCollectedAt[user] = totalRewards;

        // If the reward token is 0 we pay out this token
        if (rewardToken == address(0)) {
            super._transfer(address(this), user, rewards);
        } else {
            // Build the swap path
            address[] memory path;
            if (rewardToken == routerWrappedNativeToken) {
                path = new address[](2);
                path[0] = address(this);
                path[1] = routerWrappedNativeToken;
            } else {
                path = new address[](3);
                path[0] = address(this);
                path[1] = routerWrappedNativeToken;
                path[2] = rewardToken;
            }

            // Perform the swap and send the tokens to the user
            primaryRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    rewards,
                    0,
                    path,
                    user,
                    block.timestamp
                );
        }

        emit RewardCollected(user, rewardToken, rewards);
    }

    function outstandingRewards(address user) public view returns (uint256) {
        if (excludedFromRewards[user]) return 0;

        // If the user does not have any tokens the rewards are always 0
        uint256 userBalance = balanceOf(user);
        if (userBalance == 0) return 0;

        uint256 rewardsSinceLastClaim = totalRewards - lastCollectedAt[user];

        // Calculate the percenatage this user owns of the supply
        uint256 ppmOfSupply = (userBalance * 1_000_000) /
            tokensCollectingRewards;
        return (rewardsSinceLastClaim * ppmOfSupply) / 1_000_000;
    }

    function performBuyBack(uint256 amount)
        external
        onlyRole(FEE_ROLE)
        disableFees
    {
        require(amount <= buyBackNativeAmount);
        buyBackNativeAmount -= amount;

        // Perform the swap
        address[] memory path = new address[](2);
        path[0] = routerWrappedNativeToken;
        path[1] = address(this);
        primaryRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            address(0xdead),
            block.timestamp
        );

        // Burn the bough back amount
        uint256 burnAmount = balanceOf(address(0xdead));
        _burn(address(0xdead), burnAmount);
        emit BuyBack(amount, burnAmount);
    }

    function setMarketingFeeWallet(address payable addr)
        external
        onlyRole(FEE_ROLE)
    {
        require(addr != address(0));
        marketingFeeWallet = addr;
        emit MarketingWalletChanged(addr);
    }

    function setDevFeeWallet(address payable addr) external onlyRole(FEE_ROLE) {
        require(addr != address(0));
        devFeeWallet = addr;
        emit DevWalletChanged(addr);
    }

    function setSellBuffer(uint256 newAmount) external onlyRole(FEE_ROLE) {
        sellBuffer = newAmount;
        emit SellBufferChanged(newAmount);
    }

    function setExcludedFromFees(address addr, bool status)
        external
        onlyRole(FEE_ROLE)
    {
        excludedFromFees[addr] = status;
        emit ExcludedFromFeesChange(addr, status);
    }

    function setExcludedFromRewards(address addr, bool status)
        external
        onlyRole(FEE_ROLE)
    {
        excludedFromRewards[addr] = status;
        emit ExcludedFromRewardsChange(addr, status);
    }

    function setSafemode(bool status) external onlyRole(FEE_ROLE) {
        safemode = status;
        emit SafeModeChanged(status);
    }

    function setLpRecipient(address addr) external onlyRole(FEE_ROLE) {
        lpRecipient = addr;
        emit LpRecipientChanged(addr);
    }

    function setRewardToken(address newToken) external onlyRole(FEE_ROLE) {
        // Check if the reward token is this token ( address(0) )
        if (newToken != address(0) && newToken != routerWrappedNativeToken) {
            // Make sure the wrappedNativeToken <-> newToken pair exists
            SwapFactory factory = SwapFactory(primaryRouter.factory());
            address rewardTokenPair = factory.getPair(
                routerWrappedNativeToken,
                newToken
            );
            require(rewardTokenPair != address(0));
        }

        rewardToken = newToken;
        emit RewardTokenChanged(newToken);
    }

    // Used for receiving ether from the
    fallback() external payable {}

    receive() external payable {}

    struct FeeSettings {
        // The percentage (in PPM) that will be deducted from the transfer amount
        uint256 totalFeePPM;
        // How the fee will be distributed
        FeeDistributionSettings distribution;
    }

    struct FeeDistributionSettings {
        uint256 buybackPPM;
        uint256 autoLpPPM;
        uint256 marketingPPM;
        uint256 rewardPPM;
        uint256 devPPM;
    }

    enum TransactionType {
        Transfer,
        Buy,
        Sell
    }
}
