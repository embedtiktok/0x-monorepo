/*

  Copyright 2019 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.9;
pragma experimental ABIEncoderV2;

import "@0x/contracts-erc20/contracts/src/interfaces/IERC20Token.sol";
import "@0x/contracts-erc20/contracts/src/interfaces/IEtherToken.sol";
import "../interfaces/IUniswapExchangeFactory.sol";
import "../interfaces/IUniswapExchange.sol";
import "../interfaces/IWallet.sol";
import "../interfaces/IERC20Bridge.sol";


// solhint-disable space-after-comma
// solhint-disable not-rely-on-time
contract UniswapBridge is
    IERC20Bridge,
    IWallet
{
    /* Mainnet addresses */
    address constant public UNISWAP_EXCHANGE_FACTORY_ADDRESS = 0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95;
    address constant public WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Struct to hold `withdrawTo()` local variables in memory and to avoid
    // stack overflows.
    struct WithdrawToState {
        IUniswapExchange exchange;
        uint256 fromTokenBalance;
        IEtherToken weth;
    }

    // solhint-disable no-empty-blocks
    /// @dev Payable fallback to receive ETH from uniswap.
    function ()
        external
        payable
    {}

    /// @dev Callback for `IERC20Bridge`. Tries to buy `amount` of
    ///      `toTokenAddress` tokens by selling the entirety of the `fromTokenAddress`
    ///      token encoded in the bridge data.
    /// @param toTokenAddress The token to buy and transfer to `to`.
    /// @param to The recipient of the bought tokens.
    /// @param amount Minimum amount of `toTokenAddress` tokens to buy.
    /// @param bridgeData The abi-encoded "from" token address.
    /// @return success The magic bytes if successful.
    function withdrawTo(
        address toTokenAddress,
        address /* from */,
        address to,
        uint256 amount,
        bytes calldata bridgeData
    )
        external
        returns (bytes4 success)
    {
        // State memory object to avoid stack overflows.
        WithdrawToState memory state;
        // Decode the bridge data to get the `fromTokenAddress`.
        (address fromTokenAddress) = abi.decode(bridgeData, (address));

        // Just transfer the tokens if they're the same.
        if (fromTokenAddress == toTokenAddress) {
            IERC20Token(fromTokenAddress).transfer(to, amount);
            return BRIDGE_SUCCESS;
        }

        // Get the exchange for the token pair.
        state.exchange = _getUniswapExchangeForTokenPair(
            fromTokenAddress,
            toTokenAddress
        );
        // Grant an allowance to the exchange.
        _grantExchangeAllowance(state.exchange);
        // Get our balance of `fromTokenAddress` token.
        state.fromTokenBalance = IERC20Token(fromTokenAddress).balanceOf(address(this));
        // Get the weth contract.
        state.weth = _getWethContract();

        // Convert from WETH to a token.
        if (fromTokenAddress == address(state.weth)) {
            // Unwrap the WETH.
            state.weth.withdraw(state.fromTokenBalance);
            // Buy as much of `toTokenAddress` token with ETH as possible and
            // transfer it to `to`.
            state.exchange.ethToTokenTransferInput.value(state.fromTokenBalance)(
                // No minimum buy amount.
                0,
                // Expires after this block.
                block.timestamp,
                // Recipient is `to`.
                to
            );

        // Convert from a token to WETH.
        } else if (toTokenAddress == address(state.weth)) {
            // Buy as much ETH with `toTokenAddress` token as possible.
            uint256 ethBought = state.exchange.tokenToEthSwapInput(
                // Sell all tokens we hold.
                state.fromTokenBalance,
                // No minimum buy amount.
                0,
                // Expires after this block.
                block.timestamp
            );
            // Wrap the ETH.
            state.weth.deposit.value(ethBought)();
            // Transfer the WETH to `to`.
            IERC20Token(toTokenAddress).transfer(to, ethBought);

        // Convert from one token to another.
        } else {
            // Buy as much `toTokenAddress` token with `fromTokenAddress` token
            // and transfer it to `to`.
            state.exchange.tokenToTokenTransferInput(
                // Sell all tokens we hold.
                state.fromTokenBalance,
                // No minimum buy amount.
                0,
                // No minimum intermediate ETH buy amount.
                0,
                // Expires after this block.
                block.timestamp,
                // Recipient is `to`.
                to,
                // Convert to `toTokenAddress`.
                toTokenAddress
            );
        }
        return BRIDGE_SUCCESS;
    }

    /// @dev `SignatureType.Wallet` callback, so that this bridge can be the maker
    ///      and sign for itself in orders. Always succeeds.
    /// @return magicValue Success bytes, always.
    function isValidSignature(
        bytes32,
        bytes calldata
    )
        external
        view
        returns (bytes4 magicValue)
    {
        return LEGACY_WALLET_MAGIC_VALUE;
    }

    /// @dev Overridable way to get the weth contract.
    /// @return token The WETH contract.
    function _getWethContract()
        internal
        view
        returns (IEtherToken token)
    {
        return IEtherToken(WETH_ADDRESS);
    }

    /// @dev Overridable way to get the uniswap exchange factory contract.
    /// @return factory The exchange factory contract.
    function _getUniswapExchangeFactoryContract()
        internal
        view
        returns (IUniswapExchangeFactory factory)
    {
        return IUniswapExchangeFactory(UNISWAP_EXCHANGE_FACTORY_ADDRESS);
    }

    /// @dev Grants an unlimited allowance to the exchange for its token
    ///      on behalf of this contract.
    /// @param exchange The Uniswap token exchange.
    function _grantExchangeAllowance(IUniswapExchange exchange)
        private
    {
        address tokenAddress = exchange.toTokenAddress();
        IERC20Token(tokenAddress).approve(address(exchange), uint256(-1));
    }

    /// @dev Retrieves the uniswap exchange contract for a given token pair.
    /// @return exchange The exchange contract for the token pair.
    function _getUniswapExchangeForTokenPair(
        address fromTokenAddress,
        address toTokenAddress
    )
        private
        view
        returns (IUniswapExchange exchange)
    {
        // Whichever isn't WETH is the exchange token.
        if (fromTokenAddress != address(_getWethContract())) {
            return _getUniswapExchangeForToken(fromTokenAddress);
        }
        return _getUniswapExchangeForToken(toTokenAddress);
    }

    /// @dev Retrieves the uniswap exchange contract for a given token.
    /// @return exchange The exchange contract for the token.
    function _getUniswapExchangeForToken(address tokenAddress)
        private
        view
        returns (IUniswapExchange exchange)
    {
        exchange = _getUniswapExchangeFactoryContract().getExchange(tokenAddress);
        require(address(exchange) != address(0), "NO_UNISWAP_EXCHANGE_FOR_TOKEN");
        return exchange;
    }
}
