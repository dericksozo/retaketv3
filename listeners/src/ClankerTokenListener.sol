// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "sim-idx-generated/Generated.sol";
import "./interfaces/IClankerTokenV4_0.sol";
import "./interfaces/IV4Quoter.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./lib/MulDiv.sol";

contract ClankerTokenListener is ClankerTokenV4_0$OnTransferEvent {
    // --- Known core addresses (Base) ---
    address constant CLANKER_V4_0_0_BASE         = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    address constant CLANKER_V3_1_FACTORY_BASE   = 0x2A787b2362021cC3eEa3C24C4748a6cD5B687382;

    address constant WETH_BASE                   = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE                   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNISWAP_V4_QUOTER_BASE      = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    uint256 constant MINIMUM_ETH_VALUE           = 0.001 ether;

    // Uniswap v3 WETH/USDC pool (Base):
    address constant UNISWAP_V3_POOL_WETH_USDC_BASE = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    // Uniswap v4 dynamic fee flag
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    struct TransferData {
        address fromAddress;
        address toAddress;
        address token;
        address factory;
        uint8   factoryVersion; // 3 or 4
        uint256 value;
        uint256 ethValueInWei;
        uint256 usdcValue;
        bytes32 txHash;
        string  tokenContext;
        uint256 blockNumber;
        uint256 blockTimestamp;
        bool    sell;
    }

    // (removed unused local PoolKey struct)

    event Transfer(TransferData);

    error NotARetaketvToken();
    error AmountTooLow(uint256 amount, uint256 minAmount);
    event QuoterError(string reason);
    event QuoterLowLevelError(bytes data);

    modifier onlyRetaketvToken(EventContext memory ctx) {
        string memory tokenContext = IClankerTokenV4_0(ctx.txn.call.callee()).context();
        require(containsStreammDeployment(tokenContext), NotARetaketvToken());
        _;
    }

    function onTransferEvent(
        EventContext memory ctx,
        ClankerTokenV4_0$TransferEventParams memory inputs
    ) external override onlyRetaketvToken(ctx) {
        string memory tokenContext = IClankerTokenV4_0(ctx.txn.call.callee()).context();

        // Use ctx for deployer lookup
        (address factory, uint8 factoryVersion, address v4Hook) =
            detectFactoryAndHook(ctx, ctx.txn.call.callee());

        uint256 ethValueInWei = 0;
        uint256 usdcValue = 0;

        if (factoryVersion == 4) {
            ethValueInWei = getValueInEth(ctx.txn.call.callee(), v4Hook, inputs.value);
            require(ethValueInWei >= MINIMUM_ETH_VALUE, AmountTooLow(ethValueInWei, MINIMUM_ETH_VALUE));
            usdcValue = getValueInUsdc(ethValueInWei);
        }

        TransferData memory data = TransferData({
            fromAddress: inputs.from,
            toAddress: inputs.to,
            token: ctx.txn.call.callee(),
            value: inputs.value,
            factory: factory,
            factoryVersion: factoryVersion,
            ethValueInWei: ethValueInWei,
            usdcValue: usdcValue,
            txHash: ctx.txn.hash(),
            tokenContext: tokenContext,
            blockNumber: block.number,
            blockTimestamp: block.timestamp,
            sell: ctx.txn.call.caller() == inputs.from
        });

        emit Transfer(data);
    }

    // ---------- PRICING HELPERS (unchanged) ----------
    function getValueInUsdc(uint256 amountWei) internal view returns (uint256 amountUsdc) {
        IUniswapV3Pool pool = IUniswapV3Pool(UNISWAP_V3_POOL_WETH_USDC_BASE);
        (uint160 sqrtPriceX96,, , , , ,) = pool.slot0();
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(
            (t0 == WETH_BASE && t1 == USDC_BASE) || (t0 == USDC_BASE && t1 == WETH_BASE),
            "Unexpected pool tokens"
        );
        if (t0 == WETH_BASE) {
            amountUsdc = MulDiv.mulDiv(amountWei, priceX192, 1 << 192);
        } else {
            amountUsdc = MulDiv.mulDiv(amountWei, 1 << 192, priceX192);
        }
    }

    function getValueInEth(address token, address hook, uint256 amount) internal returns (uint256) {
        IV4Quoter.PoolKey memory poolKey = IV4Quoter.PoolKey({
            currency0: token < WETH_BASE ? token : WETH_BASE,
            currency1: token < WETH_BASE ? WETH_BASE : token,
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: hook
        });
        require(amount <= type(uint128).max, "Amount too large for uint128");
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: poolKey,
            zeroForOne: token < WETH_BASE,
            exactAmount: uint128(amount),
            hookData: hex"00"
        });
        IV4Quoter quoter = IV4Quoter(UNISWAP_V4_QUOTER_BASE);
        try quoter.quoteExactInputSingle(params) returns (uint256 amountOut, uint256) {
            return amountOut;
        } catch Error(string memory reason) {
            emit QuoterError(reason);
            return 0;
        } catch (bytes memory lowLevelData) {
            emit QuoterLowLevelError(lowLevelData);
            return 0;
        }
    }

    // ---------- classification via Sim deployer ----------
    function detectFactoryAndHook(
        EventContext memory ctx,
        address token
    ) internal returns (address factory, uint8 version, address hook) {
        address deployer = ctx.sim.getDeployer(token);
        if (deployer == CLANKER_V4_0_0_BASE) {
            return (CLANKER_V4_0_0_BASE, 4, address(0));
        }
        if (deployer == CLANKER_V3_1_FACTORY_BASE) {
            return (CLANKER_V3_1_FACTORY_BASE, 3, address(0));
        }
        return (address(0), 0, address(0));
    }


    // (removed: helper lookups for v4 hook)

    // ---------- helpers ----------
    function containsStreammDeployment(string memory tokenContext) internal pure returns (bool) {
        bytes memory contextBytes = bytes(tokenContext);
        bytes memory pattern = bytes("streamm deployment");
        if (contextBytes.length < pattern.length) return false;
        for (uint i = 0; i <= contextBytes.length - pattern.length; i++) {
            bool found = true;
            for (uint j = 0; j < pattern.length; j++) {
                if (contextBytes[i + j] != pattern[j]) { found = false; break; }
            }
            if (found) return true;
        }
        return false;
    }
}