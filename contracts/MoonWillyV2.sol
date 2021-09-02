pragma solidity ^0.8.0;

import "./ERC20.sol";
import "./Ownable.sol";
import "./interface/UniswapInterface.sol";
import "./TokenDividendTracker.sol";

contract MoonWillyV2 is ERC20, Ownable {
    using SafeMath for uint256;

    bool private swapping;

    bool public disableFees;

    TokenDividendTracker public dividendTracker;

    mapping(address => bool) private _isExcludedFromFee;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    mapping(address => bool) public whiteList;
    mapping(address => bool) public blackList;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;

    address public DAIToken = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;

    address public treasury = 0x47Eb130179cD0C25f11Da3476F2493b5A0eb7a6b;

    address public marketing = 0x8F7C10f725853323aF9aD428aCBaa3BFdD1D9A2B;

    address public airdrop = 0xA448D903442436c0841eE150520eF0737F4a2735;

    address public teamwallet = 0x65AF81855Af6be6Bf3a818167E9cf14BA3b1F1BF;

    address public burnWallet = 0xFe59c4Ce0B45997D24c03034396aCF648C9a4D1F;

    address public liquidityWallet;

    uint256 public maxSellTransactionAmount = 2500 * 1e3 * 1e18; // 0.1% of total supply 10M

    uint256 private feeUnits = 1000;
    uint256 public standardFee = 150;
    uint256 public DAIRewardFee = 80;
    uint256 public liquidityFee = 30;
    uint256 public marketingFee = 30;
    uint256 public burnFee = 10;

    uint256 public antiDumpFee = 30;
    uint256 public antiDumpMarket = 10;
    uint256 public antiDumpLiquidity = 10;
    uint256 public antiDumpBurn = 10;

    uint256 private liquidityBalance;
    uint256 private treasuryBalance;
    uint256 public swapTokensAtAmount = 200000 * (10 ** 18);

    uint256 public gasForProcessing = 300000;

    uint256 public tradingEnabledTimestamp;
    bool public tradingEnabled = true;

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event ProcessedDividendTracker(uint256 iterations, uint256 claims, uint256 lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);

    constructor() ERC20("MoonWilly", "MoonWilly") {

        dividendTracker = new TokenDividendTracker("MoonWilly_Dividend_Tracker", "MoonWilly_Dividend_Tracker", DAIToken);

        liquidityWallet = owner();

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
        .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[liquidityWallet] = true;
        _isExcludedFromFee[treasury] = true;
        _isExcludedFromFee[marketing] = true;
        _isExcludedFromFee[teamwallet] = true;
        _isExcludedFromFee[airdrop] = true;
        _isExcludedFromFee[burnWallet] = true;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(liquidityWallet);
        dividendTracker.excludeFromDividends(treasury);
        dividendTracker.excludeFromDividends(teamwallet);
        dividendTracker.excludeFromDividends(airdrop);
        dividendTracker.excludeFromDividends(burnWallet);
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));


        _mint(owner(), 1000000000 * 1e18);
        tradingEnabledTimestamp = block.timestamp.add(2 days);
    }

    receive() external payable {
    }

    function setTradingEnabled(bool _enabled) external onlyOwner {
        tradingEnabled = _enabled;
    }

    function updateStandardFees(uint256 _daiRewardFee, uint256 _liquidityFee, uint256 _marketingFee, uint256 _burnFee) external onlyOwner {
        DAIRewardFee = _daiRewardFee;
        liquidityFee = _liquidityFee;
        marketingFee = _marketingFee;
        burnFee = _burnFee;
        standardFee = _daiRewardFee + _liquidityFee + _marketingFee + _burnFee;
        require(standardFee <= 150, "Should be less than 15%");
    }

    function updateUntiDumpFees(uint256 _antiDumpMarket, uint256 _antiDumpLiquidity, uint256 _antiDumpBurn) external onlyOwner {
        antiDumpMarket = _antiDumpMarket;
        antiDumpLiquidity = _antiDumpLiquidity;
        antiDumpBurn = _antiDumpBurn;
        antiDumpFee = _antiDumpMarket + _antiDumpLiquidity + antiDumpBurn;
        require(antiDumpFee <= 50, "Should be less than 5%");
    }

    function updateLiquidityWallet(address newLiquidityWallet) external onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "MoonWilly: The liquidity wallet is already this address");
        _isExcludedFromFee[newLiquidityWallet] = true;
        liquidityWallet = newLiquidityWallet;
    }

    function excludeFromDaiReward(address _address) external onlyOwner {
        dividendTracker.excludeFromDividends(_address);
    }

    function excludeFromFee(address _address) external onlyOwner {
        _isExcludedFromFee[_address] = true;
    }

    function includeToFee(address _address) external onlyOwner {
        _isExcludedFromFee[_address] = false;
    }

    function setTradingEnabledTimestamp(uint256 timestamp) external onlyOwner {
        tradingEnabledTimestamp = timestamp;
    }

    function updateDisableFees(bool _disableFees) external onlyOwner {
        if(_disableFees) {
            _removeDust();
        }
        disableFees = _disableFees;
    }

    function addToWhiteList(address _address) external onlyOwner {
        whiteList[_address] = true;
    }

    function execludeFromWhiteList(address _address) external onlyOwner {
        whiteList[_address] = false;
    }

    function addAddressToBlackList(address _address) external onlyOwner {
        blackList[_address] = true;
    }

    function setMultiToBlackList(address[] memory _addresses, bool _black) external onlyOwner {
        for(uint i = 0; i < _addresses.length; i++) {
            blackList[_addresses[i]] = _black;
        }
    }

    function execludeAddressFromBlackList(address _address) external onlyOwner {
        blackList[_address] = false;
    }

    function updateSwapTokensAtAmount(uint256 _amount) external onlyOwner {
        swapTokensAtAmount = _amount;
    }

    function destroyTracker() external onlyOwner {
        disableFees = true;
        dividendTracker.destroyDividendTracker();
        _removeDust();
    }

    function removeBadToken(IERC20 Token) external onlyOwner {
        require(address(Token) != address(this), "You cannot remove this Token");
        Token.transfer(owner(), Token.balanceOf(address(this)));
    }

    function _removeDust() private {
        IERC20(DAIToken).transfer(owner(), IERC20(DAIToken).balanceOf(address (this)));
        IERC20(address (this)).transfer(owner(), IERC20(address (this)).balanceOf(address (this)));
        payable(owner()).send(address(this).balance);
    }

    function setDividendTracker(TokenDividendTracker _dividendTracker) external onlyOwner {
        dividendTracker = _dividendTracker;
        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(liquidityWallet);
        dividendTracker.excludeFromDividends(treasury);
        dividendTracker.excludeFromDividends(teamwallet);
        dividendTracker.excludeFromDividends(airdrop);
        dividendTracker.excludeFromDividends(burnWallet);
        dividendTracker.excludeFromDividends(address(uniswapV2Router));
        _setAutomatedMarketMakerPair(uniswapV2Pair, true);
    }

    function updateGasForProcessing(uint256 _gasForProcessing) external onlyOwner {
        gasForProcessing = _gasForProcessing;
    }

    function updateMaxSellAmount(uint256 _max) external onlyOwner {
        require(_max > 1000 * 1e18 && _max < 2500 * 1e3 * 1e18);
        maxSellTransactionAmount = _max;
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        bool noFee = _isExcludedFromFee[from] || _isExcludedFromFee[to] || disableFees;

        require(!(blackList[from] || blackList[to]), "Hacker Address Blacked");

        if(!noFee && (automatedMarketMakerPairs[from] || automatedMarketMakerPairs[to]) && !swapping) {

            require(tradingEnabled, "Trading Disabled");
            require(block.timestamp >= tradingEnabledTimestamp || whiteList[from] || whiteList[to], "Trading Still Not Enabled");

            uint256 contractBalance = balanceOf(address(this));
            if (contractBalance >= swapTokensAtAmount) {
                if (!swapping && !automatedMarketMakerPairs[from]) {
                    swapping = true;
                    swapAndLiquify();
                    swapAndSendTreasury();
                    swapAndSendDividends();
                    swapping = false;
                }
            }

            uint256 fees = amount.mul(standardFee).div(feeUnits);
            //            uint256 rewardAmount = amount.mul(DAIRewardFee).div(feeUnits);
            uint256 marketingAmount = amount.mul(marketingFee).div(feeUnits);
            uint256 liquidityAmount = amount.mul(liquidityFee).div(feeUnits);
            uint256 burnAmount = amount.mul(burnFee).div(feeUnits);
            if (automatedMarketMakerPairs[to]) {
                require(amount <= maxSellTransactionAmount, "Max Sell Amount Error");
                fees.add(amount.mul(antiDumpFee).div(feeUnits));
                marketingAmount.add(amount.mul(antiDumpMarket).div(feeUnits));
                burnAmount.add(amount.mul(antiDumpBurn).div(feeUnits));
                liquidityAmount.add(amount.mul(antiDumpLiquidity).div(feeUnits));
            }
            _burn(from, burnAmount);
            super._transfer(from, address(this), fees.sub(burnAmount));
            treasuryBalance = treasuryBalance.add(marketingAmount);
            liquidityBalance = liquidityBalance.add(liquidityAmount);
            super._transfer(from, to, amount.sub(fees));

        } else {
            super._transfer(from, to, amount);
        }

        if(!disableFees) {
            dividendTracker.setBalance(from, balanceOf(from));
            dividendTracker.setBalance(to, balanceOf(to));

            if (!swapping && !noFee) {
                uint256 gas = gasForProcessing;
                try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                    emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
                }
                catch {

                }
            }
        }
    }

    function swapAndLiquify() private {
        // split the contract balance into halves

        uint256 half = liquidityBalance.div(2);
        uint256 otherHalf = liquidityBalance.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half);
        // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        liquidityBalance = 0;
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        // add the liquidity
        uniswapV2Router.addLiquidityETH{value : ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            liquidityWallet,
            block.timestamp
        );
    }

    function swapAndSendTreasury() private {
        swapTokensForDai(treasuryBalance, treasury);
        treasuryBalance = 0;
    }

    function swapAndSendDividends() private {
        swapTokensForDai(balanceOf(address(this)), address(this));
        if(address(this).balance > 1e18) { // > 3BNB
            swapBNBForDai();
        }
        uint256 dividends = IERC20(DAIToken).balanceOf(address(this));
        bool success = IERC20(DAIToken).transfer(address(dividendTracker), dividends);
        if (success) {
            dividendTracker.distributeDaiDividends(dividends);
        }
    }

    function swapBNBForDai() private {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = DAIToken;
        // make the swap
        uniswapV2Router.swapExactETHForTokens{value : address(this).balance}(
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapTokensForDai(uint256 tokenAmount, address recipient) private {
        // generate the uniswap pair path of weth -> busd
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        path[2] = DAIToken;

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BUSD
            path,
            recipient,
            block.timestamp
        );
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != uniswapV2Pair, "MoonWilly: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs");
        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "MoonWilly: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            try dividendTracker.excludeFromDividends(pair) {
            } catch {
                // already excluded
            }
        }
        emit SetAutomatedMarketMakerPair(pair, value);
    }
}
