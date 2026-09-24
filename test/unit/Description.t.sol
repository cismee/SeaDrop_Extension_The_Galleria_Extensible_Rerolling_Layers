// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { GalleriaTestBase } from "../helpers/GalleriaTestBase.sol";
import { Base64 } from "solady/utils/Base64.sol";

/// @notice The collection description that ships in every token's metadata JSON.
///
///         It is owner-supplied plain text containing markdown links, apostrophes and
///         real newlines, emitted through `LibString.escapeJSON`. The risk being pinned
///         here is that an unescaped character breaks the JSON for all 2,618 tokens at
///         once — so these tests render a real tokenURI and parse it.
contract DescriptionTest is GalleriaTestBase {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployWithCounts(4, 3, 3, 3);
        _setEntropy(0xDE5C);
    }

    function _decode(string memory uri) internal pure returns (string memory) {
        bytes memory u = bytes(uri);
        uint256 off = bytes("data:application/json;base64,").length;
        bytes memory payload = new bytes(u.length - off);
        for (uint256 i = 0; i < payload.length; ++i) payload[i] = u[i + off];
        return string(Base64.decode(string(payload)));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // The shipped default renders as well-formed JSON.
    // ------------------------------------------------------------------
    function test_default_description_renders_valid_json() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));

        // Reverts if the description broke the JSON.
        vm.parseJson(json);

        assertTrue(_has(json, "The Galleria"), "title text present");
        assertTrue(_has(json, "2,618 NFTs"), "supply text present");
        assertTrue(_has(json, "Cartyisme"), "creator credit present");
        assertTrue(_has(json, "Heraldia"), "attribution present");
    }

    // Markdown links must survive verbatim — escapeJSON must NOT escape "/" or the
    // brackets, or every URL in the description would render mangled.
    function test_markdown_links_survive_escaping() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));

        assertTrue(
            _has(json, "[The Galleria](https://galleria.theflorentines.xyz)"),
            "galleria link intact"
        );
        assertTrue(_has(json, "[Cartyisme](https://x.com/cartyisme)"), "creator link intact");
        assertTrue(
            _has(json, "[The Florentines](https://theflorentines.xyz)"),
            "florentines link intact"
        );
        assertTrue(
            _has(json, "[Heraldia](https://opensea.io/collection/heraldia)"),
            "heraldia link intact"
        );
        assertFalse(_has(json, "https:\\/\\/"), "slashes must NOT be escaped");
    }

    // Real newlines must arrive as the two-character JSON escape \n, not as a raw
    // control byte (invalid JSON) and not as a literal backslash-n (renders wrong).
    function test_newlines_become_json_escapes() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));

        assertTrue(_has(json, "artwork.\\n\\nHandcrafted"), "paragraph break 1 escaped");
        assertTrue(_has(json, "nostalgia.\\n\\nContracts"), "paragraph break 2 escaped");

        // No raw newline (0x0A) may appear inside the JSON string.
        bytes memory b = bytes(json);
        for (uint256 i = 0; i < b.length; ++i) {
            assertTrue(b[i] != 0x0A, "raw newline would be invalid JSON");
        }
    }

    // The apostrophes in "it's" / "@_ab83_'s" are legal JSON and must pass through.
    function test_apostrophes_pass_through_unescaped() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));
        assertTrue(_has(json, "it's art history canon"), "apostrophe preserved");
        assertTrue(_has(json, "[@\\\\_ab83\\\\_](https://x.com/_ab83_)'s"), "possessive preserved");
    }

    // ------------------------------------------------------------------
    // setDescription applies to every token instantly (read live at render time).
    // ------------------------------------------------------------------
    function test_setDescription_applies_to_all_tokens_immediately() public {
        _mint(alice, 3);

        vm.prank(OWNER);
        registry.setDescription("Rewritten.");

        for (uint256 id = 1; id <= 3; ++id) {
            string memory json = _decode(token.tokenURI(id));
            vm.parseJson(json);
            assertTrue(_has(json, '"description":"Rewritten."'), "new text on every token");
        }
    }

    // A hostile description cannot break the metadata: quotes and backslashes are
    // escaped rather than terminating the JSON string early.
    function test_quotes_and_backslashes_cannot_break_json() public {
        _mint(alice, 1);

        vm.prank(OWNER);
        registry.setDescription('He said "hi" \\ then left');

        string memory json = _decode(token.tokenURI(1));
        vm.parseJson(json); // must still parse
        assertTrue(_has(json, '\\"hi\\"'), "quotes escaped");
    }

    function test_setDescription_is_owner_only() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.setDescription("nope");
    }

    // The @_ab83_ handle must render with LITERAL underscores, not as italicised
    // "ab83". Markdown needs a backslash escape, and that backslash has to survive the
    // JSON layer: stored as one `\\`, emitted by escapeJSON as `\\\\`, collapsed by the
    // JSON parser back to one, then consumed by the markdown renderer.
    function test_ab83_underscores_are_markdown_escaped() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));

        // In the raw JSON the backslash appears doubled.
        assertTrue(_has(json, "[@\\\\_ab83\\\\_]"), "escaped in JSON");

        // The URL keeps bare underscores — escaping there would break the link.
        assertTrue(_has(json, "(https://x.com/_ab83_)"), "URL underscores untouched");

        // And the unescaped form must NOT appear as link text, or it would italicise.
        assertFalse(_has(json, "[@_ab83_]"), "bare underscores would italicise");
    }

    // "Handcrafted" wording is present in the second paragraph.
    function test_handcrafted_wording_present() public {
        _mint(alice, 1);
        string memory json = _decode(token.tokenURI(1));
        assertTrue(_has(json, "Handcrafted 2-bit demakes"), "handcrafter phrasing");
    }
}
