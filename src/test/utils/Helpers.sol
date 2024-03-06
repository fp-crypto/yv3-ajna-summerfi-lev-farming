import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import "forge-std/console.sol";

library Helpers {
    function logStrategyInfo(IStrategyInterface strategy) internal view {
        (uint256 _debt, uint256 _collateral, , ) = strategy.positionInfo();
        console.log("\n");
        console.log("==== Strategy Info ====");
        console.log("Debt: %i", _debt);
        console.log("Collateral: %i", _collateral);
        console.log("LTV: %i", strategy.currentLTV());
        console.log("ETA: %i", strategy.estimatedTotalAssets());
        console.log("Total Idle: %i", strategy.totalIdle());
        console.log("Total Assets: %i", strategy.totalAssets());
    }
}
