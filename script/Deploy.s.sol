// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CollateralPolicy} from "../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../src/FarmentaMarket.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {MarketLens} from "../src/MarketLens.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {TwapRecorder} from "../src/TwapRecorder.sol";
import {RobinhoodChain} from "../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../src/interfaces/ICollateralPolicy.sol";
import {IFlashLoanMorpho, ILiquidationMarket, LiquidatorHelper} from "../src/periphery/LiquidatorHelper.sol";

/// @notice Deploys the whole protocol in one run: dependencies, one market implementation, the
///         Blue-chip and Meme proxies, a lens for each, optionally a liquidator helper for each,
///         and a `TimelockController` that owns both markets and the policy, with a guardian
///         named on all three.
/// @dev Simulate first, then broadcast, both from the `deploy` profile (the one that ships):
///
///        FOUNDRY_PROFILE=deploy OWNER=0x… GUARDIAN=0x… forge script script/Deploy.s.sol \
///            --rpc-url robinhood
///        FOUNDRY_PROFILE=deploy OWNER=0x… GUARDIAN=0x… forge script script/Deploy.s.sol \
///            --rpc-url robinhood --broadcast --private-key $PRIVATE_KEY
///
///      The linked libraries (`MarketDebt`, `MarketMint`, `MarketLiquidity`, `MarketLiquidation`,
///      `MarketUpgrade`) are deployed by forge itself, through the CREATE2 factory, before the
///      market implementation. The broadcast log under `broadcast/Deploy.s.sol/<chainid>/` keeps
///      every address, including theirs. After a broadcast, script/manifest.sh turns that log
///      into `deployments/<chainid>.json` for the off-chain services and the frontend. It has to
///      run afterwards: each contract's `startBlock` exists only in the receipts, because
///      `block.number` on this chain reports the L1 block (ARCHITECTURE §14).
///
///      External addresses default to `RobinhoodChain` on chain 4663 and are read from the
///      environment everywhere else, so another chain needs no code change (ARCHITECTURE §14).
///      Any of them can also be overridden on 4663 by setting the variable.
///
///      Ownership. The deployer is `msg.sender`, which forge sets to the `--private-key` or
///      `--sender` account. With the timelock (the default), every owner function of the markets
///      and the policy goes through it: `TIMELOCK_PROPOSER` schedules, waits `TIMELOCK_MIN_DELAY`,
///      and `TIMELOCK_EXECUTOR` executes (script/Timelock.s.sol). Both default to `OWNER`, which
///      defaults to the deployer. The timelock has no admin, so its roles and delay change only
///      through its own queue. `DEPLOY_TIMELOCK=false` skips the timelock and `OWNER` owns
///      everything directly.
///
///      Guardian. Every owner call waits the timelock's delay, and an incident does not. So
///      `GUARDIAN` is named on both markets and on the policy, and may do four things at once:
///      `pause` a market, and on the policy `freeze` a pool, `disableToken` and `revokeHook`
///      (ARCHITECTURE §4.1, §6.5, FAR-68). The reverse of each, and everything else, stays with
///      the owner. `GUARDIAN` has no default: the run stops before any transaction when it is
///      unset, `address(0)`, or the deployer, whose key is the one that sits in `.env`.
///      Replacing the guardian later is `setGuardian`, an owner call, on each of the three.
///
///      The markets get their owner in `initialize`. The policy cannot: its token configuration
///      below has to be written by its owner in this run, so it is deployed owned by the deployer
///      and handed over with `transferOwnership`. That is two-step, and the timelock can accept
///      only through its own queue: when the deployer is a proposer this run schedules the
///      `acceptOwnership()` itself, otherwise the proposer schedules it. Until it executes, the
///      deployer still owns the policy.
///
///      Pools are not listed here. Every listing is a curated decision with its own terms
///      (§6.3, §6.5) and goes through `CollateralPolicy.list` once the policy's owner has
///      reviewed the pool. Meme tokens are configured at that point too.
contract Deploy is Script {
    struct Config {
        address owner;
        address guardian;
        address positionManager;
        address stateView;
        address usdg;
        address weth;
        address ethUsdFeed;
        address usdgUsdFeed;
        address morpho;
        address universalRouter;
        bool liquidatorHelpers;
        bool timelock;
        uint256 timelockMinDelay;
        address timelockProposer;
        address timelockExecutor;
    }

    struct Deployment {
        TimelockController timelock;
        TwapRecorder recorder;
        CollateralPolicy policy;
        PriceOracle oracle;
        PositionValuer valuer;
        InterestRateModel interestRateModel;
        FarmentaMarket implementation;
        FarmentaMarket blueChip;
        FarmentaMarket meme;
        MarketLens blueChipLens;
        MarketLens memeLens;
        LiquidatorHelper blueChipLiquidator;
        LiquidatorHelper memeLiquidator;
        /// @dev Who owns the markets and, once accepted, the policy: the timelock or `OWNER`.
        address admin;
        /// @dev Named on both markets and the policy. Returned so the manifest carries it: a
        ///      reader learns who can pause without calling `guardian()` on three contracts.
        address guardian;
        /// @dev The timelock operation that accepts the policy, when this run scheduled it.
        bytes32 acceptOperation;
    }

    /// @notice Matches the market's own upgrade delay, `FarmentaMarket.TIMELOCK_DELAY`.
    uint256 public constant DEFAULT_TIMELOCK_MIN_DELAY = 2 days;

    error ZeroAddress(string name);
    error NoCode(string name, address account);
    error ZeroTimelockDelay();
    error GuardianIsTheDeployer(address deployer);

    /// @dev The returned `Deployment` lands in the broadcast log, where script/manifest.sh reads
    ///      it: keep the field order of `Deployment` in step with that script.
    function run() external returns (Deployment memory) {
        return deploy(config());
    }

    /// @notice Deploys with `c` as given, without reading the environment.
    /// @dev `run()` is `deploy(config())`. Tests call this directly, because environment
    ///      variables are shared by every test running in parallel.
    function deploy(
        Config memory c
    ) public returns (Deployment memory d) {
        address deployer = msg.sender;
        _check(c, deployer);

        vm.startBroadcast(deployer);

        if (c.timelock) {
            address[] memory proposers = new address[](1);
            proposers[0] = c.timelockProposer;
            address[] memory executors = new address[](1);
            executors[0] = c.timelockExecutor;
            d.timelock = new TimelockController(c.timelockMinDelay, proposers, executors, address(0));
            d.admin = address(d.timelock);
        } else {
            d.admin = c.owner;
        }

        d.recorder = new TwapRecorder(IStateView(c.stateView));
        d.policy = new CollateralPolicy(Currency.wrap(c.usdg), deployer);
        d.oracle = new PriceOracle(d.policy, d.recorder);
        d.guardian = c.guardian;
        d.valuer = new PositionValuer(IPositionManager(payable(c.positionManager)), IStateView(c.stateView), d.oracle);
        d.interestRateModel = new InterestRateModel();
        d.implementation = new FarmentaMarket(
            IPositionManager(payable(c.positionManager)), d.policy, d.valuer, d.oracle, d.interestRateModel
        );

        d.blueChip = _proxy(
            d.implementation, c, d.admin, "Farmenta USDG Blue-chip", "fUSDG-BC", ICollateralPolicy.Tier.BLUE_CHIP
        );
        d.meme = _proxy(d.implementation, c, d.admin, "Farmenta USDG Meme", "fUSDG-MEME", ICollateralPolicy.Tier.MEME);
        d.blueChipLens = new MarketLens(d.blueChip);
        d.memeLens = new MarketLens(d.meme);

        if (c.liquidatorHelpers) {
            d.blueChipLiquidator = new LiquidatorHelper(
                ILiquidationMarket(address(d.blueChip)), IFlashLoanMorpho(c.morpho), c.universalRouter, IERC20(c.weth)
            );
            d.memeLiquidator = new LiquidatorHelper(
                ILiquidationMarket(address(d.meme)), IFlashLoanMorpho(c.morpho), c.universalRouter, IERC20(c.weth)
            );
        }

        // USDG is the quote; ETH is priced by the same feed whether it arrives native or wrapped.
        d.policy
            .setTokenConfig(
                Currency.wrap(c.usdg),
                true,
                ICollateralPolicy.Tier.BLUE_CHIP,
                RobinhoodChain.USDG_DECIMALS,
                c.usdgUsdFeed
            );
        d.policy
            .setTokenConfig(
                Currency.wrap(c.weth),
                true,
                ICollateralPolicy.Tier.BLUE_CHIP,
                RobinhoodChain.WETH_DECIMALS,
                c.ethUsdFeed
            );
        d.policy
            .setTokenConfig(
                Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.BLUE_CHIP, 18, c.ethUsdFeed
            );

        // While the deployer still owns the policy: afterwards this is the timelock's call.
        d.policy.setGuardian(c.guardian);

        if (d.admin != deployer) d.policy.transferOwnership(d.admin);
        if (c.timelock && c.timelockProposer == deployer) {
            bytes memory accept = abi.encodeCall(d.policy.acceptOwnership, ());
            d.timelock.schedule(address(d.policy), 0, accept, bytes32(0), bytes32(0), c.timelockMinDelay);
            d.acceptOperation = d.timelock.hashOperation(address(d.policy), 0, accept, bytes32(0), bytes32(0));
        }
        vm.stopBroadcast();

        _verify(d, c, deployer);
        _log(d, c, deployer);
    }

    /// @notice The configuration `run()` deploys with, before any transaction is sent.
    function config() public view returns (Config memory c) {
        bool robinhood = block.chainid == RobinhoodChain.CHAIN_ID;
        c.owner = vm.envOr("OWNER", msg.sender);
        // No default: `_check` refuses the zero this leaves when the variable is unset.
        c.guardian = vm.envOr("GUARDIAN", address(0));
        c.positionManager = _address("POSITION_MANAGER", robinhood, RobinhoodChain.POSITION_MANAGER);
        c.stateView = _address("STATE_VIEW", robinhood, RobinhoodChain.STATE_VIEW);
        c.usdg = _address("USDG", robinhood, RobinhoodChain.USDG);
        c.weth = _address("WETH", robinhood, RobinhoodChain.WETH);
        c.ethUsdFeed = _address("CHAINLINK_ETH_USD", robinhood, RobinhoodChain.CHAINLINK_ETH_USD);
        c.usdgUsdFeed = _address("CHAINLINK_USDG_USD", robinhood, RobinhoodChain.CHAINLINK_USDG_USD);
        c.liquidatorHelpers = vm.envOr("DEPLOY_LIQUIDATOR_HELPERS", true);
        if (c.liquidatorHelpers) {
            c.morpho = _address("MORPHO_BLUE", robinhood, RobinhoodChain.MORPHO_BLUE);
            c.universalRouter = _address("UNIVERSAL_ROUTER", robinhood, RobinhoodChain.UNIVERSAL_ROUTER);
        }
        c.timelock = vm.envOr("DEPLOY_TIMELOCK", true);
        if (c.timelock) {
            c.timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);
            c.timelockProposer = vm.envOr("TIMELOCK_PROPOSER", c.owner);
            c.timelockExecutor = vm.envOr("TIMELOCK_EXECUTOR", c.owner);
        }
    }

    /// @dev The guardian goes in through `initialize`: the proxy is its owner's from that call
    ///      on, and under a timelock owner `setGuardian` would wait the delay.
    function _proxy(
        FarmentaMarket implementation,
        Config memory c,
        address owner,
        string memory name,
        string memory symbol,
        ICollateralPolicy.Tier tier
    ) private returns (FarmentaMarket) {
        bytes memory init =
            abi.encodeCall(FarmentaMarket.initialize, (IERC20(c.usdg), name, symbol, tier, owner, c.guardian));
        return FarmentaMarket(payable(address(new ERC1967Proxy(address(implementation), init))));
    }

    /// @dev Refuses to spend gas against a wrong address: every external dependency must exist.
    ///      A mistyped feed or token would otherwise surface only when the first borrow reverts.
    function _check(
        Config memory c,
        address deployer
    ) private view {
        if (c.owner == address(0)) revert ZeroAddress("OWNER");
        if (c.guardian == address(0)) revert ZeroAddress("GUARDIAN");
        // The deployer's key is the one in `.env`. A guardian is the key that is reached for
        // in an incident, and it should not be the one a deploy machine holds.
        if (c.guardian == deployer) revert GuardianIsTheDeployer(deployer);
        _hasCode("POSITION_MANAGER", c.positionManager);
        _hasCode("STATE_VIEW", c.stateView);
        _hasCode("USDG", c.usdg);
        _hasCode("WETH", c.weth);
        _hasCode("CHAINLINK_ETH_USD", c.ethUsdFeed);
        _hasCode("CHAINLINK_USDG_USD", c.usdgUsdFeed);
        if (c.liquidatorHelpers) {
            _hasCode("MORPHO_BLUE", c.morpho);
            _hasCode("UNIVERSAL_ROUTER", c.universalRouter);
        }
        if (c.timelock) {
            if (c.timelockMinDelay == 0) revert ZeroTimelockDelay();
            if (c.timelockProposer == address(0)) revert ZeroAddress("TIMELOCK_PROPOSER");
            // address(0) as executor would let anyone execute a ready operation; say so explicitly
            // by choosing it on purpose rather than by an unset variable.
            if (c.timelockExecutor == address(0)) revert ZeroAddress("TIMELOCK_EXECUTOR");
        }
    }

    /// @dev Reads back what was deployed. The oracle calls reach the live feeds, so a feed that
    ///      is stale or not a price feed stops the run here, in the simulation, before broadcast.
    function _verify(
        Deployment memory d,
        Config memory c,
        address deployer
    ) private view {
        require(d.blueChip.tier() == ICollateralPolicy.Tier.BLUE_CHIP, "blue-chip tier");
        require(d.meme.tier() == ICollateralPolicy.Tier.MEME, "meme tier");
        require(d.blueChip.owner() == d.admin && d.meme.owner() == d.admin, "market owner");
        require(d.blueChip.asset() == c.usdg && d.meme.asset() == c.usdg, "market asset");
        require(_implementation(d.blueChip) == address(d.implementation), "blue-chip implementation");
        require(_implementation(d.meme) == address(d.implementation), "meme implementation");
        require(address(d.implementation.positionManager()) == c.positionManager, "market position manager");
        require(address(d.implementation.policy()) == address(d.policy), "market policy");
        require(address(d.implementation.oracle()) == address(d.oracle), "market oracle");
        require(address(d.implementation.valuer()) == address(d.valuer), "market valuer");
        require(address(d.implementation.interestRateModel()) == address(d.interestRateModel), "market IRM");
        require(address(d.oracle.policy()) == address(d.policy), "oracle policy");
        require(address(d.oracle.recorder()) == address(d.recorder), "oracle recorder");
        require(address(d.valuer.oracle()) == address(d.oracle), "valuer oracle");
        require(address(d.blueChipLens.market()) == address(d.blueChip), "blue-chip lens");
        require(address(d.memeLens.market()) == address(d.meme), "meme lens");
        if (c.liquidatorHelpers) {
            require(address(d.blueChipLiquidator.market()) == address(d.blueChip), "blue-chip liquidator");
            require(address(d.memeLiquidator.market()) == address(d.meme), "meme liquidator");
        }
        require(d.blueChip.guardian() == c.guardian, "blue-chip guardian");
        require(d.meme.guardian() == c.guardian, "meme guardian");
        require(d.policy.guardian() == c.guardian, "policy guardian");
        require(d.policy.owner() == deployer, "policy owner");
        require(d.policy.pendingOwner() == (d.admin == deployer ? address(0) : d.admin), "policy pending owner");
        require(d.oracle.price(Currency.wrap(c.usdg)) > 0, "USDG price");
        require(d.oracle.price(Currency.wrap(c.weth)) > 0, "WETH price");
        if (c.timelock) {
            TimelockController t = d.timelock;
            require(t.getMinDelay() == c.timelockMinDelay, "timelock delay");
            require(t.hasRole(t.PROPOSER_ROLE(), c.timelockProposer), "timelock proposer");
            require(t.hasRole(t.CANCELLER_ROLE(), c.timelockProposer), "timelock canceller");
            require(t.hasRole(t.EXECUTOR_ROLE(), c.timelockExecutor), "timelock executor");
            require(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer), "deployer is timelock admin");
            require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)), "timelock is not its own admin");
        }
    }

    function _log(
        Deployment memory d,
        Config memory c,
        address deployer
    ) private view {
        console2.log("Deployer", deployer);
        console2.log("Owner of markets and policy", d.admin);
        console2.log("Guardian of markets and policy", c.guardian);
        console2.log("TimelockController", address(d.timelock));
        console2.log("TwapRecorder", address(d.recorder));
        console2.log("CollateralPolicy", address(d.policy));
        console2.log("PriceOracle", address(d.oracle));
        console2.log("PositionValuer", address(d.valuer));
        console2.log("InterestRateModel", address(d.interestRateModel));
        console2.log("FarmentaMarket implementation", address(d.implementation));
        console2.log("FarmentaMarket Blue-chip (proxy)", address(d.blueChip));
        console2.log("FarmentaMarket Meme (proxy)", address(d.meme));
        console2.log("MarketLens Blue-chip", address(d.blueChipLens));
        console2.log("MarketLens Meme", address(d.memeLens));
        console2.log("LiquidatorHelper Blue-chip", address(d.blueChipLiquidator));
        console2.log("LiquidatorHelper Meme", address(d.memeLiquidator));

        if (block.chainid == RobinhoodChain.CHAIN_ID && c.owner == deployer) {
            console2.log("WARNING: OWNER is the deployer. The timelock's proposer and executor are the key");
            console2.log("         that sent this deploy; set OWNER to a separate key or a multisig");
        }
        if (d.admin == deployer) return;
        if (d.acceptOperation != bytes32(0)) {
            console2.log("Scheduled on the timelock: CollateralPolicy.acceptOwnership(), operation id");
            console2.logBytes32(d.acceptOperation);
            console2.log("Executable after (seconds)", c.timelockMinDelay);
        } else if (c.timelock) {
            console2.log("Next: TIMELOCK_PROPOSER schedules CollateralPolicy.acceptOwnership() on the timelock");
        } else {
            console2.log("Next: OWNER calls acceptOwnership() on CollateralPolicy");
        }
    }

    function _implementation(
        FarmentaMarket proxy
    ) private view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _address(
        string memory name,
        bool robinhood,
        address robinhoodDefault
    ) private view returns (address account) {
        account = robinhood ? vm.envOr(name, robinhoodDefault) : vm.envAddress(name);
        if (account == address(0)) revert ZeroAddress(name);
    }

    function _hasCode(
        string memory name,
        address account
    ) private view {
        if (account.code.length == 0) revert NoCode(name, account);
    }
}
