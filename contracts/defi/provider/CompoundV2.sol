pragma solidity ^0.5.4;
import "../../wallet/BaseWallet.sol";
import "../../exchange/ERC20.sol";
import "../../utils/SafeMath.sol";
import "../Invest.sol";
import "../Loan.sol";

interface Comptroller {
    function enterMarkets(address[] calldata _cTokens) external returns (uint[] memory);
    function exitMarket(address _cToken) external returns (uint);
    function getAssetsIn(address _account) external view returns (address[] memory);
    function getAccountLiquidity(address _account) external view returns (uint, uint, uint);
}

interface CompoundRegistry {
    function getCToken(address _token) external view returns (address);
    function getComptroller() external view returns (address);
}

interface CToken {
    function comptroller() external view returns (address);
    function underlying() external view returns (address);
    function exchangeRateCurrent() external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function borrowBalanceCurrent(address _account) external view returns (uint256);
}

/**
 * @title CompoundV2
 * @dev Wrapper contract to integrate Compound V2.
 * @author Julien Niset - <julien@argent.xyz>
 */
contract CompoundV2 is Invest, Loan {

    address constant internal ETH_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    using SafeMath for uint256;

    /* ********************************** Implementation of Invest ************************************* */

    /**
     * @dev Invest tokens for a given period.
     * @param _wallet The target wallet.
     * @param _tokens The array of token address.
     * @param _amounts The amount to invest for each token.
     * @param _period The period over which the tokens may be locked in the investment (optional).
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function addInvestment(
        BaseWallet _wallet, 
        address[] calldata _tokens, 
        uint256[] calldata _amounts, 
        uint256 _period, 
        address _oracle
    ) 
        external 
    {
        for(uint i = 0; i < _tokens.length; i++) {
            address cToken = CompoundRegistry(_oracle).getCToken(_tokens[i]);
            mint(_wallet, cToken, _tokens[i], _amounts[i]);
        }
    }

    /**
     * @dev Exit invested postions.
     * @param _wallet The target wallet.s
     * @param _tokens The array of token address.
     * @param _fractions The fraction of invested tokens to exit in per 10000. 
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function removeInvestment(
        BaseWallet _wallet, 
        address[] calldata _tokens, 
        uint256 _fraction, 
        address _oracle
    ) 
        external 
    {
        for(uint i = 0; i < _tokens.length; i++) {
            address cToken = CompoundRegistry(_oracle).getCToken(_tokens[i]);
            uint shares = ERC20(cToken).balanceOf(address(_wallet));
            redeem(_wallet, cToken, shares.mul(_fraction).div(10000));
        }
    }

    /**
     * @dev Get the amount of investment in a given token.
     * @param _wallet The target wallet.
     * @param _token The token address.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     * @return The value in tokens of the investment (including interests) and the time at which the investment can be removed.
     */
    function getInvestment(
        BaseWallet _wallet, 
        address _token, 
        address _oracle
    ) 
        external 
        view 
        returns (uint256 _tokenValue, uint256 _periodEnd) 
    {
        address cToken = CompoundRegistry(_oracle).getCToken(_token);
        uint amount = CToken(cToken).balanceOf(address(_wallet));
        uint exchangeRateMantissa = CToken(cToken).exchangeRateCurrent();
        _tokenValue = amount.mul(exchangeRateMantissa).div(10 ** 18);
        _periodEnd = 0;
    }

    /* ********************************** Implementation of Loan ************************************* */

    /**
     * @dev Opens a collateralized loan.
     * @param _wallet The target wallet.
     * @param _collateralToken The token used as a collateral.
     * @param _collateralAmount The amount of collateral token provided.
     * @param _debtToken The token borrowed.
     * @param _debtAmount The amount of tokens borrowed.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     * @return (optional) An ID for the loan when the provider enables users to create multiple distinct loans.
     */
    function openLoan(
        BaseWallet _wallet, 
        address _collateral, 
        uint256 _collateralAmount, 
        address _debtToken, 
        uint256 _debtAmount, 
        address _oracle
    ) 
        external 
        returns (bytes32 _loanId) 
    {
        address cToken = CompoundRegistry(_oracle).getCToken(_collateral);
        address dToken = CompoundRegistry(_oracle).getCToken(_debtToken);
        address comptroller = CToken(cToken).comptroller();
        _wallet.invoke(comptroller, 0, abi.encodeWithSignature("enterMarkets(address[])", [cToken, dToken]));
        mint(_wallet, cToken, _collateral, _collateralAmount);
        borrow(_wallet, dToken, _debtAmount);
    }

    /**
     * @dev Closes a collateralized loan by repaying all debts (plus interest) and redeeming all collateral (plus interest).
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function closeLoan(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _oracle
    ) 
        external 
    {
        address comptroller = CompoundRegistry(_oracle).getComptroller();
        address[] memory markets = Comptroller(comptroller).getAssetsIn(address(_wallet));
        for(uint i = 0; i < markets.length; i++) {
            address cToken = markets[i];
            uint collateral = CToken(cToken).balanceOf(address(_wallet));
            uint debt = CToken(cToken).borrowBalanceCurrent(address(_wallet));
            if(collateral > 0) {
                redeem(_wallet, cToken, collateral);
            }
            if(debt > 0) {
                repayBorrow(_wallet, cToken, CToken(cToken).underlying(), debt);
            }
            _wallet.invoke(comptroller, 0, abi.encodeWithSignature("exitMarket(address)", cToken));
        }
    }

    /**
     * @dev Adds collateral to a loan identified by its ID.
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _collateral The token used as a collateral.
     * @param _collateralAmount The amount of collateral to add.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function addCollateral(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _collateral, 
        uint256 _collateralAmount, 
        address _oracle
    ) 
        external 
    {
        address cToken = CompoundRegistry(_oracle).getCToken(_collateral);
        enterMarketIfNeeded(_wallet, cToken);
        mint(_wallet, cToken, _collateral, _collateralAmount);
    }

    /**
     * @dev Removes collateral from a loan identified by its ID.
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _collateral The token used as a collateral.
     * @param _collateralAmount The amount of collateral to remove.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function removeCollateral(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _collateral, 
        uint256 _collateralAmount, 
        address _oracle
    ) 
        external 
    {
        address cToken = CompoundRegistry(_oracle).getCToken(_collateral);
        redeemUnderlying(_wallet, cToken, _collateralAmount);
        exitMarketIfNeeded(_wallet, cToken);
    }

    /**
     * @dev Increases the debt by borrowing more token from a loan identified by its ID.
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _debtToken The token borrowed.
     * @param _debtAmount The amount of token to borrow.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function addDebt(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _debtToken, 
        uint256 _debtAmount, 
        address _oracle
    ) 
        external 
    {
        address dToken = CompoundRegistry(_oracle).getCToken(_debtToken);
        enterMarketIfNeeded(_wallet, dToken);
        borrow(_wallet, dToken, _debtAmount);
    }

    /**
     * @dev Decreases the debt by repaying some token from a loan identified by its ID.
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _debtToken The token to repay.
     * @param _debtAmount The amount of token to repay.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     */
    function removeDebt(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _debtToken, 
        uint256 _debtAmount, 
        address _oracle
    ) 
        external
    {
        address dToken = CompoundRegistry(_oracle).getCToken(_debtToken);
        repayBorrow(_wallet, dToken, _debtToken, _debtAmount);
        exitMarketIfNeeded(_wallet, dToken);
    }

    /**
     * @dev Gets information about a loan identified by its ID.
     * @param _wallet The target wallet.
     * @param _loanId The ID of the loan if any, 0 otherwise.
     * @param _oracle (optional) The address of an oracle contract that may be used by the provider to query information on-chain.
     * @return a status [0: no loan, 1: loan is safe, 2: loan is unsafe and can be liquidated] and the estimated ETH value of the loan
     * combining all collaterals and all debts. When status = 1 it represents the value that could still be borrowed, while with status = 2
     * it represents the value of collateral that should be added to avoid liquidation.      
     */
    function getLoan(
        BaseWallet _wallet, 
        bytes32 _loanId, 
        address _oracle
    ) 
        external 
        view 
        returns (uint8 _status, uint256 _ethValue)
    {
        address comptroller = CompoundRegistry(_oracle).getComptroller();
        (uint error, uint liquidity, uint shortfall) = Comptroller(comptroller).getAccountLiquidity(address(_wallet));
        require(error == 0, "Compound: failed to get account liquidity");
        if(liquidity > 0) {
            return (1, liquidity);
        }
        if(shortfall > 0) {
            return (2, shortfall);
        }
        return (0,0);
    }

    /* ****************************************** Compound wrappers ******************************************* */

    /**
     * @dev Adds underlying tokens to a cToken contract.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     * @param _token The underlying token.
     * @param _amount The amount of underlying token to add.
     */
    function mint(BaseWallet _wallet, address _cToken, address _token, uint256 _amount) internal {
        require(_cToken != address(0), "Compound: No market for target token");
        require(_amount > 0, "Compound: amount cannot be 0");
        if(_token == ETH_TOKEN_ADDRESS) {
            _wallet.invoke(_cToken, _amount, abi.encodeWithSignature("mint()"));
        }
        else {
            _wallet.invoke(_token, 0, abi.encodeWithSignature("approve(address,uint256)", _cToken, _amount));
            _wallet.invoke(_cToken, 0, abi.encodeWithSignature("mint(uint256)", _amount));
        }
    }

    /**
     * @dev Redeems underlying tokens from a cToken contract.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     * @param _amount The amount of cToken to redeem.
     */
    function redeem(BaseWallet _wallet, address _cToken, uint256 _amount) internal {     
        require(_cToken != address(0), "Compound: No market for target token");   
        require(_amount > 0, "Compound: amount cannot be 0");
        _wallet.invoke(_cToken, 0, abi.encodeWithSignature("redeem(uint256)", _amount));
    }

    /**
     * @dev Redeems underlying tokens from a cToken contract.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     * @param _amount The amount of underlying token to redeem.
     */
    function redeemUnderlying(BaseWallet _wallet, address _cToken, uint256 _amount) internal {     
        require(_cToken != address(0), "Compound: No market for target token");   
        require(_amount > 0, "Compound: amount cannot be 0");
        _wallet.invoke(_cToken, 0, abi.encodeWithSignature("redeemUnderlying(uint256)", _amount));
    }

    /**
     * @dev Borrows underlying tokens from a cToken contract.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     * @param _amount The amount of underlying tokens to borrow.
     */
    function borrow(BaseWallet _wallet, address _cToken, uint256 _amount) internal {
        require(_cToken != address(0), "Compound: No market for target token");
        require(_amount > 0, "Compound: amount cannot be 0");
        _wallet.invoke(_cToken, 0, abi.encodeWithSignature("borrow(uint256)", _amount));
    }

    /**
     * @dev Repays some borrowed underlying tokens to a cToken contract.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     * @param _token The underlying token.
     * @param _amount The amount of tokens to repay.
     */
    function repayBorrow(BaseWallet _wallet, address _cToken, address _token, uint256 _amount) internal {
        require(_cToken != address(0), "Compound: No market for target token");
        require(_amount > 0, "Compound: amount cannot be 0");
        if(_token == ETH_TOKEN_ADDRESS) {
            _wallet.invoke(_cToken, _amount, abi.encodeWithSignature("repayBorrow()"));
        }
        else {
            _wallet.invoke(_token, 0, abi.encodeWithSignature("approve(address,uint256)", _cToken, _amount));
            _wallet.invoke(_cToken, 0, abi.encodeWithSignature("repayBorrow(uint256)", _amount));
        }
    }

    /**
     * @dev Enters a cToken market if it was not entered before.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     */
    function enterMarketIfNeeded(BaseWallet _wallet, address _cToken) internal {
        address comptroller = CToken(_cToken).comptroller();
        address[] memory markets = Comptroller(comptroller).getAssetsIn(address(_wallet));
        for(uint i = 0; i < markets.length; i++) {
            if(markets[i] == _cToken) {
                return;
            }
        }
        _wallet.invoke(comptroller, 0, abi.encodeWithSignature("enterMarkets(address[])", [_cToken]));
    }

    /**
     * @dev Exits a cToken market if there is no more collateral and debt.
     * @param _wallet The target wallet.
     * @param _cToken The cToken contract.
     */
    function exitMarketIfNeeded(BaseWallet _wallet, address _cToken) internal {
        uint collateral = CToken(_cToken).balanceOf(address(_wallet));
        uint debt = CToken(_cToken).borrowBalanceCurrent(address(_wallet));
        if(collateral == 0 && debt == 0) {
            address comptroller = CToken(_cToken).comptroller();
            _wallet.invoke(comptroller, 0, abi.encodeWithSignature("exitMarket(address)", _cToken));
        }
    }
}