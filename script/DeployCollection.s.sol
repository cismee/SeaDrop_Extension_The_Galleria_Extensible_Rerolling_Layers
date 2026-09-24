// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script, console2 } from "forge-std/Script.sol";
import { Galleria } from "../src/Galleria.sol";
import { TraitRegistry } from "../src/TraitRegistry.sol";
import { PublicDrop } from "seadrop/lib/SeaDropStructs.sol";

/**
 * @title  DeployCollection
 * @notice Deploys the Galleria token, wires it to a SeaDrop, and (optionally)
 *         configures a public drop. The registry must be deployed first
 *         (DeployRegistry) and its address passed in.
 *
 *         env:
 *           REGISTRY        (address) — deployed TraitRegistry.
 *           SEADROP_ADDRESS (address) — SeaDrop impl (mainnet: 0x00005EA0...bf5).
 *           PRIVATE_KEY     (uint)    — deployer key.
 *           TIMELOCK        (address) — optional; if set, ownership is handed to it.
 *           CONFIGURE_DROP  (bool)    — optional; if true, set fee recipient /
 *                                       creator payout / public drop on the SeaDrop.
 *           FEE_RECIPIENT, CREATOR_PAYOUT (address) — used when CONFIGURE_DROP.
 */
contract DeployCollection is Script {
    function run() external returns (Galleria token) {
        address registry = vm.envAddress("REGISTRY");
        address seaDrop = vm.envOr(
            "SEADROP_ADDRESS",
            0x00005EA00Ac477B1030CE78506496e8C2dE24bf5
        );
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));

        address[] memory allowedSeaDrop = new address[](1);
        allowedSeaDrop[0] = seaDrop;

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        token = new Galleria(
            "The Galleria",
            "GALLERIA",
            allowedSeaDrop,
            TraitRegistry(registry)
        );
        console2.log("Galleria:", address(token));
        console2.log("  registry:", address(token.registry()));
        console2.log("  maxSupply:", token.maxSupply());

        // Optional: configure the SeaDrop public drop. Requires `seaDrop` to be a
        // real deployed SeaDrop; guarded so a bare deploy still succeeds.
        if (vm.envOr("CONFIGURE_DROP", false)) {
            address feeRecipient = vm.envAddress("FEE_RECIPIENT");
            address creatorPayout = vm.envAddress("CREATOR_PAYOUT");

            token.updateCreatorPayoutAddress(seaDrop, creatorPayout);
            token.updateAllowedFeeRecipient(seaDrop, feeRecipient, true);
            token.updatePublicDrop(
                seaDrop,
                PublicDrop({
                    mintPrice: 0.01 ether,
                    startTime: uint48(block.timestamp),
                    endTime: uint48(block.timestamp + 7 days),
                    maxTotalMintableByWallet: 10,
                    feeBps: 500, // 5%
                    restrictFeeRecipients: true
                })
            );
            console2.log("  public drop configured");
        }

        // Optional: hand ownership to the timelock/multisig (two-step; the
        // timelock must then accept via acceptOwnership()).
        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock != address(0)) {
            token.transferOwnership(timelock);
            console2.log("  ownership transfer initiated to:", timelock);
        }

        vm.stopBroadcast();
    }
}
