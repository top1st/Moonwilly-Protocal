pragma solidity ^0.8.0;

import "./ERC20.sol";
import "./Ownable.sol";
import "./interface/UniswapInterface.sol";
import "./TokenDividendTracker.sol";

contract MoonWillyV2 is ERC20, Ownable {
    using SafeMath for uint256;

    bool private swapping;

    TokenDividendTracker public dividendTracker;

    mapping(address => bool) private _isExcludedFromFee;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

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

    uint256 private feeUnits = 100;
    uint256 public standardFee = 15;
    uint256 public DAIRewardFee = 8;
    uint256 public liquidityFee = 3;
    uint256 public marketingFee = 3;
    uint256 public burnFee = 1;

    uint256 public antiDumpFee = 3;
    uint256 public antiDumpMarket = 1;
    uint256 public antiDumpLiquidity = 1;
    uint256 public antiDumpBurn = 1;

    uint256 private liquidityBalance;
    uint256 private treasuryBalance;
    uint256 public swapTokensAtAmount = 200000 * (10 ** 18);

    uint256 public gasForProcessing = 300000;

    uint256 public tradingEnabledTimestamp;

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event ProcessedDividendTracker(uint256 iterations, uint256 claims, uint256 lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);

    constructor() ERC20("MoonWilly", "MNWL") {

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
        tradingEnabledTimestamp = block.timestamp;
    }

    receive() external payable {
    }

    function updateLiquidityWallet(address newLiquidityWallet) public onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "MoonWilly: The liquidity wallet is already this address");
        _isExcludedFromFee[newLiquidityWallet] = true;
        liquidityWallet = newLiquidityWallet;
    }

    function setTradingEnabledTimestamp(uint256 timestamp) external onlyOwner {
        tradingEnabledTimestamp = timestamp;
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

        bool noFee = _isExcludedFromFee[from] || _isExcludedFromFee[to];

        if (!swapping && !noFee && from != address(uniswapV2Router)) {
            if (tradingEnabledTimestamp.add(5 minutes) > block.timestamp) {
                require(amount <= maxSellTransactionAmount, "anti whale feature for first 2 minutes");
            }
        }

        if (!swapping && !noFee) {
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
        }

        if (noFee || swapping) {
            super._transfer(from, to, amount);
        } else {
            uint256 fees = amount.mul(standardFee).div(feeUnits);
//            uint256 rewardAmount = amount.mul(DAIRewardFee).div(feeUnits);
            uint256 marketingAmount = amount.mul(marketingFee).div(feeUnits);
            uint256 liquidityAmount = amount.mul(liquidityFee).div(feeUnits);
            uint256 burnAmount = amount.mul(burnFee).div(feeUnits);
            if (automatedMarketMakerPairs[to]) {
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
        }


        dividendTracker.setBalance(payable(from), balanceOf(from));
        dividendTracker.setBalance(payable(to), balanceOf(to));

        if (!swapping && !noFee) {
            uint256 gas = gasForProcessing;
            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            }
            catch {

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
        if(address(this).balance > 3e18) { // > 3BNB
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
        require(automatedMarketMakerPairs[pair] != value, "AkuAku: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

}
