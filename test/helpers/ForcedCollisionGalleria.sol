// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Galleria } from "../../src/Galleria.sol";
import { TraitRegistry } from "../../src/TraitRegistry.sol";

/**
 * @notice A Galleria whose per-attempt candidate combos can be scripted, so the
 *         collision-handling paths (lock-until-success ordering, capmiss-is-noop)
 *         can be driven deterministically instead of hoping the RNG collides.
 *
 *         When a script is set, `_sampleCombo` returns `script[attempt]` (clamped
 *         to the last entry), letting a test lay out an exact sequence of taken /
 *         free candidates for one settle call.
 */
contract ForcedCollisionGalleria is Galleria {
    uint256[] internal _script;
    bool public scripted;

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory allowedSeaDrop_,
        TraitRegistry registry_
    ) Galleria(name_, symbol_, allowedSeaDrop_, registry_) {}

    function setScript(uint256[] calldata combos) external {
        delete _script;
        for (uint256 i = 0; i < combos.length; ++i) {
            _script.push(combos[i]);
        }
        scripted = true;
    }

    function clearScript() external {
        scripted = false;
    }

    function _sampleCombo(
        uint256 tokenId,
        uint256 attempt,
        uint256 entropyBase
    ) internal view override returns (uint256) {
        if (scripted) {
            uint256 idx = attempt < _script.length ? attempt : _script.length - 1;
            return _script[idx];
        }
        return super._sampleCombo(tokenId, attempt, entropyBase);
    }
}
