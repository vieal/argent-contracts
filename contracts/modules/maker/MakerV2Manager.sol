pragma solidity ^0.5.4;

import "./MakerV2Base.sol";
import "./MakerV2Invest.sol";
import "./MakerV2Loan.sol";

/**
 * @title MakerV2Manager
 * @dev Module to convert SAI <-> DAI, lock/unlock MCD DAI into/from Maker's Pot,
 * migrate old CDPs and open and manage new CDPs.
 * @author Olivier VDB - <olivier@argent.xyz>
 */
contract MakerV2Manager is MakerV2Base, MakerV2Invest, MakerV2Loan {

    // *************** Constructor ********************** //

    constructor(
        ModuleRegistry _registry,
        GuardianStorage _guardianStorage,
        ScdMcdMigration _scdMcdMigration,
        PotLike _pot,
        JugLike _jug,
        MakerRegistry _makerRegistry,
        IUniswapFactory _uniswapFactory
    )
        MakerV2Base(_registry, _guardianStorage, _scdMcdMigration)
        MakerV2Invest(_pot)
        MakerV2Loan(_jug, _makerRegistry, _uniswapFactory)
        public
    {
    }

}