// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IBookKeeper.sol";
import "../interfaces/IStabilityFeeCollector.sol";
import "../interfaces/IPausable.sol";

contract StabilityFeeCollectorMath {
    uint256 internal constant RAY = 10 ** 27;

    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 {
                    z := b
                }
                default {
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    z := b
                }
                default {
                    z := x
                }
                let half := div(b, 2) // for rounding.
                for {
                    n := div(n, 2)
                } n {
                    n := div(n, 2)
                } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) {
                        revert(0, 0)
                    }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }
                    x := div(xxRound, b)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }
                        z := div(zxRound, b)
                    }
                }
            }
        }
    }

    function add(uint256 _x, uint256 _y) internal pure returns (uint256 _z) {
        _z = _x + _y;
        require(_z >= _x);
    }

    function diff(uint256 _x, uint256 _y) internal pure returns (int256 _z) {
        _z = int256(_x) - int256(_y);
        require(int256(_x) >= 0 && int256(_y) >= 0);
    }

    function rmul(uint256 _x, uint256 _y) internal pure returns (uint256 _z) {
        _z = _x * _y;
        require(_y == 0 || _z / _y == _x);
        _z = _z / RAY;
    }
}

/** @notice A contract which acts as a collector for the stability fee.
    The stability fee is a fee that is collected from the minter of Fathom Stablecoin in a per-seconds basis.
    The stability fee will be accumulated in the system as a surplus to settle any bad debt.
*/
contract StabilityFeeCollector is StabilityFeeCollectorMath, PausableUpgradeable, ReentrancyGuardUpgradeable, IStabilityFeeCollector, IPausable {
    struct CollateralPool {
        uint256 stabilityFeeRate; // Collateral-specific, per-second stability fee debtAccumulatedRate or mint interest debtAccumulatedRate [ray]
        uint256 lastAccumulationTime; // Time of last call to `collect` [unix epoch time]
    }

    IBookKeeper public bookKeeper;
    address public systemDebtEngine;

    event LogSetSystemDebtEngine(address indexed _caller, address _data);

    modifier onlyOwner() {
        IAccessControlConfig _accessControlConfig = IAccessControlConfig(bookKeeper.accessControlConfig());
        require(_accessControlConfig.hasRole(_accessControlConfig.OWNER_ROLE(), msg.sender), "!ownerRole");
        _;
    }

    modifier onlyOwnerOrGov() {
        IAccessControlConfig _accessControlConfig = IAccessControlConfig(IBookKeeper(bookKeeper).accessControlConfig());
        require(
            _accessControlConfig.hasRole(_accessControlConfig.OWNER_ROLE(), msg.sender) ||
                _accessControlConfig.hasRole(_accessControlConfig.GOV_ROLE(), msg.sender),
            "!(ownerRole or govRole)"
        );
        _;
    }

    function initialize(address _bookKeeper, address _systemDebtEngine) external initializer {
        PausableUpgradeable.__Pausable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        bookKeeper = IBookKeeper(_bookKeeper);
        require(_systemDebtEngine != address(0), "StabilityFeeCollector/bad-system-debt-engine-address");
        systemDebtEngine = _systemDebtEngine;
    }

    function pause() external override onlyOwnerOrGov {
        _pause();
    }

    function unpause() external override onlyOwnerOrGov {
        _unpause();
    }

    function setSystemDebtEngine(address _systemDebtEngine) external onlyOwner {
        require(_systemDebtEngine != address(0), "StabilityFeeCollector/bad-system-debt-engine-address");
        systemDebtEngine = _systemDebtEngine;
        emit LogSetSystemDebtEngine(msg.sender, _systemDebtEngine);
    }

    /** @dev Collect the stability fee of the collateral pool.
      This function could be called by anyone.
      It will update the `debtAccumulatedRate` of the specified collateral pool according to
      the global and per-pool stability fee rates with respect to the last block that `collect` was called.
    */
    function collect(bytes32 _collateralPool) external override whenNotPaused nonReentrant returns (uint256 _debtAccumulatedRate) {
        _debtAccumulatedRate = _collect(_collateralPool);
    }

    function _collect(bytes32 _collateralPoolId) internal returns (uint256 _debtAccumulatedRate) {
        uint256 _previousDebtAccumulatedRate = ICollateralPoolConfig(bookKeeper.collateralPoolConfig()).getDebtAccumulatedRate(_collateralPoolId);
        uint256 _stabilityFeeRate = ICollateralPoolConfig(bookKeeper.collateralPoolConfig()).getStabilityFeeRate(_collateralPoolId);
        uint256 _lastAccumulationTime = ICollateralPoolConfig(bookKeeper.collateralPoolConfig()).getLastAccumulationTime(_collateralPoolId);
        require(block.timestamp >= _lastAccumulationTime, "StabilityFeeCollector/invalid-block.timestamp");
        require(systemDebtEngine != address(0), "StabilityFeeCollector/system-debt-engine-not-set");

        _debtAccumulatedRate = rmul(rpow(_stabilityFeeRate, block.timestamp - _lastAccumulationTime, RAY), _previousDebtAccumulatedRate);

        bookKeeper.accrueStabilityFee(_collateralPoolId, systemDebtEngine, diff(_debtAccumulatedRate, _previousDebtAccumulatedRate));
        ICollateralPoolConfig(bookKeeper.collateralPoolConfig()).updateLastAccumulationTime(_collateralPoolId);
    }
}
