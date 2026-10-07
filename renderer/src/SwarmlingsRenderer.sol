// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwarmlingsData as D} from "./SwarmlingsData.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";
import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";

/// @title Swarmlings renderer
/// @notice Immutable, ownerless art for the 3,333 Swarmlings: hand-drawn robot portraits printed as
/// risograph halftone screens in eight inks on cream paper. Everything is derived here from the id;
/// nothing is stored and nothing can change.
/// @dev A byte-for-byte port of art/riso2.mjs; test/Renderer.t.sol checks all 3,333 ids and the logo.
contract SwarmlingsRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    error UnknownId(uint256 id);

    uint256 public constant SUPPLY = D.SUPPLY;
    bytes32 public constant SALT = D.SALT;

    // eight inks, each with its own screen angle; tone 1..4 sets the dot radius
    bytes private constant INK_HEX = hex"ff48b00078bfffd400ff6c2f00a95c765ba72b3a871c1b1f";
    bytes private constant INK_ANGLE = hex"0f4b001e3c2d692d";
    bytes private constant RADIUS = hex"0305070a";
    uint256 private constant PINK = 0;
    uint256 private constant BLUE = 1;
    uint256 private constant YELLOW = 2;
    uint256 private constant ORANGE = 3;
    uint256 private constant GREEN = 4;
    uint256 private constant INDIGO = 6;
    uint256 private constant BLACK = 7;
    uint256 private constant NO_INK = 0xff;

    bytes private constant CHASSIS_INK = hex"040301020605070200"; // Teal .. Chrome
    bytes private constant SIGNAL_INK = hex"02010004ff"; // Amber .. White (bare paper)
    bytes private constant BG_INK = hex"060504030204050001"; // Midnight .. Grid
    bytes private constant BG_TONE = hex"010202010101010101";

    /// per head, uint16 each: head rr (x y w h r, r = 0 for a drawn path), top, visor rr (x y w h r), eye y, side x
    bytes private constant HEADS =
        hex"0280030c02d002bc0046030c02da0410021c00d2006904790280"
        hex"028002f802d002e400e602f802da0410021c00d2006904790280"
        hex"00000000000000000000030c02da0424021c00c8006404880280"
        hex"02a802b20280035c014002b202ee041001f400d20069047902a8"
        hex"024e033403340294003c033402a80398028001b800280474024e"
        hex"00000000000000000000032002da03e8021c00c80064044c0280";

    bytes private constant BODY = "M500 2040V1980C500 1760 640 1620 1000 1620C1360 1620 1500 1760 1500 1980V2040Z";
    bytes private constant DOME =
        "M640 1430V1140A360 360 0 0 1 1360 1140V1430A70 70 0 0 1 1290 1500H710A70 70 0 0 1 640 1430Z";
    bytes private constant SHIELD =
        "M700 800H1300A60 60 0 0 1 1360 860V1180C1360 1380 1180 1500 1000 1540C820 1500 640 1380 640 1180V860A60 60 0 0 1 700 800Z";
    bytes private constant MUL = '" style="mix-blend-mode:multiply"/>';

    /// one print job: the output, which (ink, tone) screens it used, and the per-ink misregistration
    struct Ctx {
        DynamicBufferLib.DynamicBuffer b;
        uint256 used; // bit ink * 4 + tone - 1
        int256[8] off;
        uint256 S; // signal ink, NO_INK for White
        uint256 C; // chassis ink
        uint256 SH; // shadow ink
        uint256[7] t; // Background, Chassis, Head, Visor, Signal, Headgear, Accessory
        bytes head;
        bytes visor;
        uint256 T; // head top
        uint256 ey; // eye line
        uint256 side; // head side at eye level
    }

    // ------------------------------------------------------------------ traits

    /// @notice The seed every trait of `id` comes from.
    function seedOf(uint256 id) public pure returns (uint256) {
        if (id == 0 || id > SUPPLY) revert UnknownId(id);
        return uint256(keccak256(abi.encode(id, SALT, uint8(_isOverride(id) ? 1 : 0))));
    }

    /// @notice Trait indexes of `id`, in the order Background, Chassis, Head, Visor, Signal, Headgear, Accessory.
    function traitsOf(uint256 id) public pure returns (uint256[7] memory t) {
        t = _traits(seedOf(id));
    }

    /// @notice Seven trait bytes per id for ids start..start+count-1, for sites that filter the collection.
    function traitsRange(uint256 start, uint256 count) external pure returns (bytes memory out) {
        out = new bytes(count * 7);
        for (uint256 n; n < count; ++n) {
            uint256[7] memory t = traitsOf(start + n);
            for (uint256 k; k < 7; ++k) out[n * 7 + k] = bytes1(uint8(t[k]));
        }
    }

    function _traits(uint256 seed) private pure returns (uint256[7] memory t) {
        bytes memory w = D.WEIGHTS;
        bytes memory off = D.OFFSETS;
        for (uint256 k; k < 7; ++k) {
            uint256 r = ((seed >> (16 * k)) & 0xffff) % 100;
            uint256 a = uint8(off[k]);
            uint256 b = uint8(off[k + 1]);
            uint256 s;
            t[k] = b - a - 1;
            for (uint256 j = a; j < b; ++j) {
                s += uint8(w[j]);
                if (s > r) {
                    t[k] = j - a;
                    break;
                }
            }
        }
    }

    function _isOverride(uint256 id) private pure returns (bool) {
        bytes memory o = D.OVERRIDES;
        for (uint256 i; i < o.length; i += 2) {
            if ((uint256(uint8(o[i])) << 8 | uint8(o[i + 1])) == id) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ outputs

    /// @notice ERC-721 metadata: data:application/json;base64 with the onchain SVG and seven attributes.
    function tokenURI(uint256 id) external pure returns (string memory) {
        uint256[7] memory t = traitsOf(id);
        DynamicBufferLib.DynamicBuffer memory j;
        j.p('{"name":"Swarmling #', bytes(LibString.toString(id)), '","description":"One of 3,333 onchain robots that live in a LING balance, printed in riso. Built by the IMD swarm.","image":"data:image/svg+xml;base64,');
        j.p(bytes(Base64.encode(bytes(svg(id)))), '","attributes":[');
        string[7] memory keys = ["Background", "Chassis", "Head", "Visor", "Signal", "Headgear", "Accessory"];
        for (uint256 k; k < 7; ++k) {
            j.p(k == 0 ? bytes('{"trait_type":"') : bytes(',{"trait_type":"'), bytes(keys[k]), '","value":"');
            j.p(bytes(_name(k, t[k])), '"}');
        }
        j.p("]}");
        return string.concat("data:application/json;base64,", Base64.encode(j.data));
    }

    /// @notice The raw SVG of `id`.
    function svg(uint256 id) public pure returns (string memory) {
        uint256 seed = seedOf(id);
        Ctx memory c;
        c.t = _traits(seed);
        for (uint256 k; k < 8; ++k) c.off[k] = int256(((seed >> (8 * k + 128)) & 0xff) % 9) - 4;
        c.S = uint8(SIGNAL_INK[c.t[4]]);
        c.C = uint8(CHASSIS_INK[c.t[1]]);
        c.SH = c.t[1] == 3 ? GREEN : c.t[1] == 7 ? ORANGE : INDIGO;
        _loadHead(c);

        _back(c);
        _rear(c);
        _face(c);
        _front(c);

        DynamicBufferLib.DynamicBuffer memory o;
        o.p('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2000 2000"><defs>', _patterns(c.used));
        o.p('<mask id="hm"><path d="', c.head, '" fill="#fff"/><path d="', c.head, '" fill="#000" transform="translate(-90 -80)"/></mask>');
        o.p('<mask id="bm"><path d="', BODY, '" fill="#fff"/><path d="', BODY, '" fill="#000" transform="translate(-170 -90)"/></mask>');
        o.p('<filter id="hand" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.008" numOctaves="2" seed="', _u((id * 13) % 997), '" result="w"/><feDisplacementMap in="SourceGraphic" in2="w" scale="22" xChannelSelector="R" yChannelSelector="G" result="a"/>');
        o.p('<feTurbulence type="fractalNoise" baseFrequency="0.12" numOctaves="1" seed="', _u((id * 17) % 997), '" result="r"/><feDisplacementMap in="a" in2="r" scale="6" xChannelSelector="R" yChannelSelector="G"/></filter>');
        o.p('<filter id="g" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.45" numOctaves="2" seed="', _u(id % 997), '"/><feColorMatrix type="matrix" values="0 0 0 0 0.35 0 0 0 0 0.28 0 0 0 0 0.18 0 0 0 0.16 0"/></filter>');
        o.p('<filter id="s" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.28" numOctaves="1" seed="', _u((id * 7) % 997), '"/><feColorMatrix type="matrix" values="0 0 0 0 0.96 0 0 0 0 0.93 0 0 0 0 0.85 9 0 0 0 -5.6"/></filter>');
        o.p('</defs><rect width="2000" height="2000" fill="#f4ecd8"/><g filter="url(#hand)">', c.b.data);
        o.p('</g><rect width="2000" height="2000" filter="url(#s)"/><rect width="2000" height="2000" filter="url(#g)"/></svg>');
        return o.s();
    }

    /// @notice The Swarmlings mark: one Swarmling head on a yellow halftone disc, printed like the tokens.
    function logoSVG() external pure returns (string memory) {
        Ctx memory c;
        c.off[PINK] = 4;
        c.off[BLUE] = 3;
        c.off[BLACK] = -3;
        c.S = NO_INK;
        bytes memory head = _rr(220, 330, 560, 480, 170);
        bytes memory visor = _rr(285, 470, 430, 170, 85);

        c.b.p('<circle cx="500" cy="500" r="430" fill="', _fill(c, YELLOW, 3), MUL, '<g transform="translate(60 70) scale(0.88)">');
        _stroke(c, INDIGO, "M500 360V180", 22);
        bytes memory d = _dot(500, 150, 62);
        _paper(c, d);
        _ink(c, YELLOW, 4, d);
        _ink(c, PINK, 4, _dot(486, 140, 24));
        _contour(c, d, 14);
        for (uint256 x = 178; x <= 742; x += 564) {
            d = _rr(x, 500, 80, 200, 38);
            _paper(c, d);
            _ink(c, INDIGO, 4, d);
            _contour(c, d, 14);
        }
        _paper(c, head);
        _ink(c, BLUE, 2, head);
        c.b.p('<g mask="url(#hm)">');
        _ink(c, BLUE, 4, head);
        _ink(c, INDIGO, 2, head);
        c.b.p('</g><ellipse cx="335" cy="425" rx="62" ry="34" fill="#f4ecd8" transform="rotate(-28 335 425)"/>');
        _contour(c, head, 18);
        _paper(c, visor);
        _ink(c, BLACK, 4, visor);
        _contour(c, visor, 14);
        c.b.p('<path d="', _rr(340, 500, 90, 28, 14), '" fill="#f4ecd8" opacity="0.85"/>');
        for (uint256 x = 395; x <= 605; x += 210) {
            d = _rr(x - 58, 528, 116, 64, 32);
            _paper(c, d);
            _ink(c, PINK, 4, d);
        }
        c.b.p("</g>");

        DynamicBufferLib.DynamicBuffer memory o;
        o.p('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><defs>', _patterns(c.used));
        o.p('<mask id="hm"><path d="', head, '" fill="#fff"/><path d="', head, '" fill="#000" transform="translate(-80 -70)"/></mask>');
        o.p('<filter id="hand" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.012" numOctaves="2" seed="18" result="w"/><feDisplacementMap in="SourceGraphic" in2="w" scale="9" xChannelSelector="R" yChannelSelector="G" result="a"/><feTurbulence type="fractalNoise" baseFrequency="0.2" numOctaves="1" seed="22" result="r"/><feDisplacementMap in="a" in2="r" scale="3" xChannelSelector="R" yChannelSelector="G"/></filter>');
        o.p('<filter id="g" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="13"/><feColorMatrix type="matrix" values="0 0 0 0 0.35 0 0 0 0 0.28 0 0 0 0 0.18 0 0 0 0.16 0"/></filter>');
        o.p('<filter id="s" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency="0.55" numOctaves="1" seed="16"/><feColorMatrix type="matrix" values="0 0 0 0 0.96 0 0 0 0 0.93 0 0 0 0 0.85 9 0 0 0 -5.6"/></filter>');
        o.p('</defs><rect width="1000" height="1000" fill="#f4ecd8"/><g filter="url(#hand)">', c.b.data);
        o.p('</g><rect width="1000" height="1000" filter="url(#s)"/><rect width="1000" height="1000" filter="url(#g)"/></svg>');
        return o.s();
    }

    // ------------------------------------------------------------------ the portrait, back to front

    function _loadHead(Ctx memory c) private pure {
        uint256 at = c.t[2] * 26;
        uint256 r = _h(at + 8);
        c.head = r == 0 ? (c.t[2] == 2 ? DOME : SHIELD) : _rr(_h(at), _h(at + 2), _h(at + 4), _h(at + 6), r);
        c.T = _h(at + 10);
        c.visor = _rr(_h(at + 12), _h(at + 14), _h(at + 16), _h(at + 18), _h(at + 20));
        c.ey = _h(at + 22);
        c.side = _h(at + 24);
    }

    /// disc, cast shadow, body, chest, neck, scarf
    function _back(Ctx memory c) private pure {
        uint256 disc = uint8(BG_INK[c.t[0]]);
        c.b.p('<circle cx="1000" cy="1080" r="760" fill="', _fill(c, disc, uint8(BG_TONE[c.t[0]])), '" transform="', _tr(c, disc), '"/>');
        c.b.p('<g transform="translate(70 60)" opacity="0.85">');
        _ink(c, INDIGO, 1, BODY);
        _ink(c, INDIGO, 1, c.head);
        c.b.p("</g>");
        _shaded(c, BODY, "bm");

        _piece(c, _rr(900, 1790, 200, 110, 26), c.C, 4, INDIGO, 3, 10);
        uint256 a = c.t[6];
        if (a == 4) {
            bytes memory d = _rr(1150, 1760, 180, 120, 20);
            _paper(c, d);
            _contour(c, d, 12);
            _ink(c, BLACK, 4, _rr(1190, 1810, 100, 22, 11));
        } else if (a == 7) {
            _piece(c, "M1260 1770A56 56 0 1 1 1259 1770Z", YELLOW, 4, NO_INK, 0, 10);
            _ink(c, BLACK, 4, "M1260 1806A20 20 0 1 1 1259 1806Z");
        }
        _piece(c, _rr(900, 1440, 200, 220, 30), c.C, 4, c.SH, 2, 14);
        if (a == 5) {
            _scarf(c, _rr(1080, 1630, 90, 230, 40));
            _scarf(c, _rr(800, 1570, 400, 100, 50));
        }
    }

    function _scarf(Ctx memory c, bytes memory d) private pure {
        if (c.S != NO_INK) _piece(c, d, c.S, 3, INDIGO, 1, 10);
        else _piece(c, d, INDIGO, 2, NO_INK, 0, 10);
    }

    /// everything that rises from behind the head
    function _rear(Ctx memory c) private pure {
        uint256 g = c.t[5];
        if (g == 1) {
            _stroke(c, INDIGO, _t(c, "M1000 {T+40}V{T-170}", 0), 22);
            _ball(c, 1000, c.T - 220, 48);
        } else if (g == 2) {
            _stroke(c, INDIGO, _t(c, "M820 {T+40}L760 {T-150}M1180 {T+40}L1240 {T-150}", 0), 20);
            _ball(c, 760, c.T - 190, 38);
            _ball(c, 1240, c.T - 190, 38);
        } else if (g == 3) {
            _stroke(c, INDIGO, _t(c, "M1000 {T+40}V{T-120}", 0), 36);
            _piece(c, _t(c, "M820 {T-150}A180 52 0 1 0 1180 {T-150}A180 52 0 1 0 820 {T-150}Z", 0), c.C, 1, NO_INK, 0, 0);
            _ink(c, c.SH, 2, _t(c, "M820 {T-150}A180 52 0 0 0 1180 {T-150}Z", 0));
            _contour(c, _t(c, "M820 {T-150}A180 52 0 1 0 1180 {T-150}A180 52 0 1 0 820 {T-150}Z", 0), 10);
            _ball(c, 1000, c.T - 150, 22);
        } else if (g == 6) {
            bytes memory fin = _t(c, "M930 {T+60}C950 {T-150} 1070 {T-230} 1100 {T-210}C1050 {T-140} 1070 {T-50} 1070 {T+60}Z", 0);
            _piece(c, fin, c.C, 2, NO_INK, 0, 0);
            _ink(c, c.SH, 2, _t(c, "M1040 {T+60}C1040 {T-70} 1060 {T-150} 1100 {T-210}C1050 {T-140} 1070 {T-50} 1070 {T+60}Z", 0));
            _contour(c, fin, 10);
        } else if (g == 8) {
            _piece(c, _t(c, "M1000 {T-290}C1130 {T-190} 1200 {T-80} 1120 {T+60}H880C800 {T-80} 870 {T-170} 1000 {T-290}Z", 0), ORANGE, 4, NO_INK, 0, 10);
            _ink(c, YELLOW, 4, _t(c, "M1000 {T-170}C1060 {T-120} 1090 {T-50} 1050 {T+40}H950C910 {T-50} 940 {T-110} 1000 {T-170}Z", 0));
        } else if (g == 5) {
            _stroke(c, YELLOW, _t(c, "M770 {T-150}A230 58 0 1 1 1230 {T-150}A230 58 0 1 1 770 {T-150}", 0), 30);
        }
        if (c.t[6] == 1) _stroke(c, INDIGO, _t(c, "M600 1150C600 {T-150} 1400 {T-150} 1400 1150", 0), 40);
    }

    /// head, visor glass, eyes
    function _face(Ctx memory c) private pure {
        _shaded(c, c.head, "hm");
        _piece(c, c.visor, BLACK, 4, NO_INK, 0, 10);
        uint256 ey = c.ey;
        bool crt = c.t[2] == 4;
        c.b.p('<path d="', _rr(crt ? 720 : 780, crt ? 960 : ey - 80, 110, 34, 17), '" fill="#f4ecd8" opacity="0.85"/>');

        uint256 v = c.t[3];
        if (v == 0 || v == 8) {
            _sig(c, 4, _rr(815, ey - 30, 120, 60, 30));
            _sig(c, 4, _rr(1065, ey - 30, 120, 60, 30));
        } else if (v == 1) {
            _sig(c, 2, _rr(790, ey - 18, 420, 36, 18));
            _sig(c, 4, _rr(920, ey - 22, 160, 44, 22));
        } else if (v == 2) {
            _sig(c, 2, _dot(1000, ey, 95));
            _sig(c, 4, _dot(1000, ey, 55));
        } else if (v == 3) {
            _sigLine(c, bytes.concat(_t(c, "M{X-55} {E+15}Q{X} {E+50} {X+55} {E+15}", 875), _t(c, "M{X-55} {E+15}Q{X} {E+50} {X+55} {E+15}", 1125)), 26);
        } else if (v == 4) {
            _sigLine(c, bytes.concat(_t(c, "M{X-55} {E+30}Q{X} {E-50} {X+55} {E+30}", 875), _t(c, "M{X-55} {E+30}Q{X} {E-50} {X+55} {E+30}", 1125)), 28);
        } else if (v == 5) {
            bytes memory d = bytes.concat(
                _t(c, "M{X-45} {E-45}L{X+45} {E+45}M{X+45} {E-45}L{X-45} {E+45}", 875),
                _t(c, "M{X-45} {E-45}L{X+45} {E+45}M{X+45} {E-45}L{X-45} {E+45}", 1125)
            );
            _paperLine(c, d, 26);
            _line(c, PINK, 4, d, 26);
        } else if (v == 6) {
            for (uint256 x = 875; x <= 1125; x += 250) {
                bytes memory d = _t(c, "M{X} {E+50}C{X-95} {E-10} {X-55} {E-85} {X} {E-40}C{X+55} {E-85} {X+95} {E-10} {X} {E+50}Z", x);
                _paper(c, d);
                _ink(c, PINK, 4, d);
            }
        } else if (v == 7) {
            _sig(c, 4, _rr(800, ey - 48, 170, 28, 14));
            _sig(c, 2, _rr(900, ey - 6, 260, 26, 13));
            _sig(c, 4, _rr(1040, ey + 34, 160, 28, 14));
        }
        if (c.t[6] == 6) {
            c.b.p('<path d="', _t(c, "M960 {E-95}L1010 {E-30}L975 {E+15}L1045 {E+95}", 0), '" fill="none" stroke="#f4ecd8" stroke-width="12" stroke-linejoin="round"/>');
        }
    }

    /// face details, ear cups, headgear that sits on the head, laser beams
    function _front(Ctx memory c) private pure {
        uint256 a = c.t[6];
        if (a == 2) {
            _ink(c, PINK, 2, "M790 1290A64 34 0 1 1 789 1290Z");
            _ink(c, PINK, 2, "M1210 1290A64 34 0 1 1 1209 1290Z");
        } else if (a == 3) {
            _piece(c, _dot(610, 1146, 36), INDIGO, 3, NO_INK, 0, 10);
            _piece(c, _dot(1390, 1146, 36), INDIGO, 3, NO_INK, 0, 10);
        } else if (a == 1) {
            for (uint256 x = 548; x <= 1352; x += 804) {
                _piece(c, _rr(x, 1030, 100, 250, 46), INDIGO, 4, NO_INK, 0, 10);
                _sig(c, 4, _rr(x + 30, 1100, 40, 110, 20));
            }
        }

        uint256 g = c.t[5];
        if (g == 7) {
            bytes memory crown = _t(c, "M760 {T+30}L760 {T-130}L870 {T-40}L1000 {T-200}L1130 {T-40}L1240 {T-130}L1240 {T+30}Z", 0);
            _piece(c, crown, YELLOW, 4, NO_INK, 0, 0);
            _ink(c, ORANGE, 2, _t(c, "M760 {T-10}H1240V{T+30}H760Z", 0));
            _contour(c, crown, 10);
            _ball(c, 1000, c.T - 74, 34);
        } else if (g == 4) {
            _stroke(c, INDIGO, _t(c, "M1000 {T-120}V{T-20}", 0), 26);
            bytes memory cap = _t(c, "M760 {T+20}A240 130 0 0 1 1240 {T+20}Z", 0);
            if (c.S != NO_INK) _piece(c, cap, c.S, 3, NO_INK, 0, 10);
            else _piece(c, cap, INDIGO, 1, NO_INK, 0, 10);
            _piece(c, _t(c, "M740 {T-125}A130 28 0 1 1 1000 {T-125}A130 28 0 1 1 740 {T-125}Z", 0), PINK, 3, NO_INK, 0, 10);
            _piece(c, _t(c, "M1000 {T-125}A130 28 0 1 1 1260 {T-125}A130 28 0 1 1 1000 {T-125}Z", 0), BLUE, 3, NO_INK, 0, 10);
        }
        if (c.t[3] == 8) _sigLine(c, _t(c, "M500 {E}H{S-10}M{X} {E}H1500", 2010 - c.side), 30);
    }

    /// head or body: light chassis, a crescent of dark chassis + shadow ink through mask `m`, outline;
    /// the head also gets a bare-paper highlight
    function _shaded(Ctx memory c, bytes memory d, bytes memory m) private pure {
        _paper(c, d);
        _ink(c, c.C, 2, d);
        c.b.p('<g mask="url(#', m, ')">');
        _ink(c, c.C, 4, d);
        _ink(c, c.SH, 2, d);
        c.b.p("</g>");
        if (m[0] == "h") {
            c.b.p(_t(c, '<ellipse cx="790" cy="{T+120}" rx="80" ry="44" fill="#f4ecd8" transform="rotate(-24 790 {T+120})"/>', 0));
        }
        _contour(c, d, 14);
    }

    /// knockout, up to two screens, then the outline (w = 0 leaves the outline to the caller)
    function _piece(Ctx memory c, bytes memory d, uint256 k1, uint256 t1, uint256 k2, uint256 t2, uint256 w) private pure {
        _paper(c, d);
        _ink(c, k1, t1, d);
        if (k2 != NO_INK) _ink(c, k2, t2, d);
        if (w != 0) _contour(c, d, w);
    }

    /// expands {T±n} head top, {E±n} eye line, {S±n} head side, {X±n} the caller's x, into a path
    function _t(Ctx memory c, bytes memory s, uint256 x) private pure returns (bytes memory) {
        DynamicBufferLib.DynamicBuffer memory o;
        uint256 i;
        while (i < s.length) {
            bytes1 ch = s[i];
            if (ch != "{") {
                uint256 j = i;
                while (j < s.length && s[j] != "{") ++j;
                o.p(_slice(s, i, j));
                i = j;
                continue;
            }
            bytes1 v = s[i + 1];
            uint256 base = v == "T" ? c.T : v == "E" ? c.ey : v == "S" ? c.side : x;
            i += 2;
            bool neg = s[i] == "-";
            uint256 n;
            if (s[i] != "}") {
                ++i;
                while (s[i] != "}") n = n * 10 + uint8(s[i++]) - 48;
            }
            ++i;
            o.p(_u(neg ? base - n : base + n));
        }
        return o.data;
    }

    function _slice(bytes memory s, uint256 a, uint256 b) private pure returns (bytes memory out) {
        out = new bytes(b - a);
        for (uint256 k; k < out.length; ++k) out[k] = s[a + k];
    }

    // ------------------------------------------------------------------ print primitives

    /// a halftone screen filling `d`, offset by its plate's misregistration, overprinted (multiply)
    function _ink(Ctx memory c, uint256 k, uint256 tone, bytes memory d) private pure {
        c.b.p('<path d="', d, '" fill="', _fill(c, k, tone), '" transform="', _tr(c, k), MUL);
    }

    function _line(Ctx memory c, uint256 k, uint256 tone, bytes memory d, uint256 w) private pure {
        c.b.p('<path d="', d, '" fill="none" stroke="', _fill(c, k, tone), '" stroke-width="', _u(w), '" stroke-linecap="round" stroke-linejoin="round" transform="');
        c.b.p(_tr(c, k), MUL);
    }

    /// knockout: bare paper in the shape of a piece, so it hides whatever is behind it
    function _paper(Ctx memory c, bytes memory d) private pure {
        c.b.p('<path d="', d, '" fill="#f4ecd8"/>');
    }

    function _paperLine(Ctx memory c, bytes memory d, uint256 w) private pure {
        c.b.p('<path d="', d, '" fill="none" stroke="#f4ecd8" stroke-width="', _u(w), '" stroke-linecap="round" stroke-linejoin="round"/>');
    }

    /// the black key plate's outline of a piece
    function _contour(Ctx memory c, bytes memory d, uint256 w) private pure {
        c.b.p('<path d="', d, '" fill="none" stroke="#1c1b1f" stroke-width="', _u(w), '" stroke-linejoin="round" transform="', _tr(c, BLACK), '"/>');
    }

    /// signal-colored shape on a paper base (bare paper when the signal is White)
    function _sig(Ctx memory c, uint256 tone, bytes memory d) private pure {
        _paper(c, d);
        if (c.S != NO_INK) _ink(c, c.S, tone, d);
    }

    function _sigLine(Ctx memory c, bytes memory d, uint256 w) private pure {
        _paperLine(c, d, w);
        if (c.S != NO_INK) _line(c, c.S, 4, d, w);
    }

    /// an outlined rod: black under, paper core, ink on top
    function _stroke(Ctx memory c, uint256 k, bytes memory d, uint256 w) private pure {
        c.b.p('<path d="', d, '" fill="none" stroke="#1c1b1f" stroke-width="', _u(w + 16), '" stroke-linecap="round" transform="', _tr(c, BLACK), '"/>');
        _paperLine(c, d, w);
        _line(c, k, 4, d, w);
    }

    function _ball(Ctx memory c, uint256 cx, uint256 cy, uint256 r) private pure {
        bytes memory d = _dot(cx, cy, r);
        _paper(c, d);
        if (c.S != NO_INK) _ink(c, c.S, 4, d);
        _contour(c, d, 10);
    }

    function _patterns(uint256 used) private pure returns (bytes memory out) {
        for (uint256 i; i < 32; ++i) {
            if (used >> i & 1 == 0) continue;
            uint256 k = i >> 2;
            out = bytes.concat(
                out, '<pattern id="', bytes(_inkName(k)), _u((i & 3) + 1),
                '" width="18" height="18" patternUnits="userSpaceOnUse" patternTransform="rotate(', _u(uint8(INK_ANGLE[k])),
                bytes.concat(')"><circle cx="9" cy="9" r="', _u(uint8(RADIUS[i & 3])), '" fill="#', bytes(LibString.toHexStringNoPrefix(_inkRgb(k), 3)), '"/></pattern>')
            );
        }
    }

    // ------------------------------------------------------------------ helpers

    function _fill(Ctx memory c, uint256 k, uint256 tone) private pure returns (bytes memory) {
        c.used |= 1 << (k * 4 + tone - 1);
        return bytes.concat("url(#", bytes(_inkName(k)), _u(tone), ")");
    }

    function _tr(Ctx memory c, uint256 k) private pure returns (bytes memory) {
        bytes memory o = bytes(LibString.toString(c.off[k]));
        return bytes.concat("translate(", o, " ", o, ")");
    }

    /// rounded rectangle, the same path the reference builds
    function _rr(uint256 x, uint256 y, uint256 w, uint256 h, uint256 r) private pure returns (bytes memory) {
        bytes memory arc = bytes.concat("A", _u(r), " ", _u(r), " 0 0 1 ");
        bytes memory xl = _u(x + r);
        bytes memory yt = _u(y);
        return bytes.concat(
            bytes.concat("M", xl, " ", yt, "H", _u(x + w - r), arc, _u(x + w), " ", _u(y + r)),
            bytes.concat("V", _u(y + h - r), arc, _u(x + w - r), " ", _u(y + h), "H", xl),
            bytes.concat(arc, _u(x), " ", _u(y + h - r), "V", _u(y + r), arc, xl, " ", yt, "Z")
        );
    }

    /// circle as one arc that stops a unit short of closing
    function _dot(uint256 cx, uint256 cy, uint256 r) private pure returns (bytes memory) {
        bytes memory y = _u(cy - r);
        bytes memory rs = _u(r);
        return bytes.concat("M", _u(cx), " ", y, "A", rs, " ", rs, " 0 1 1 ", _u(cx - 1), " ", y, "Z");
    }

    function _h(uint256 at) private pure returns (uint256) {
        return uint256(uint8(HEADS[at])) << 8 | uint8(HEADS[at + 1]);
    }

    function _u(uint256 x) private pure returns (bytes memory) {
        return bytes(LibString.toString(x));
    }

    function _inkName(uint256 k) private pure returns (string memory) {
        return ["pink", "blue", "yellow", "orange", "green", "violet", "indigo", "black"][k];
    }

    function _inkRgb(uint256 k) private pure returns (uint256) {
        return uint256(uint8(INK_HEX[k * 3])) << 16 | uint256(uint8(INK_HEX[k * 3 + 1])) << 8 | uint8(INK_HEX[k * 3 + 2]);
    }

    function _name(uint256 k, uint256 idx) private pure returns (string memory) {
        bytes memory s = bytes(
            [
                D.NAMES_BACKGROUND,
                D.NAMES_CHASSIS,
                D.NAMES_HEAD,
                D.NAMES_VISOR,
                D.NAMES_SIGNAL,
                D.NAMES_HEADGEAR,
                D.NAMES_ACCESSORY
            ][k]
        );
        uint256 start;
        uint256 n;
        for (uint256 i; i <= s.length; ++i) {
            if (i == s.length || s[i] == "|") {
                if (n == idx) {
                    bytes memory out = new bytes(i - start);
                    for (uint256 j; j < out.length; ++j) out[j] = s[start + j];
                    return string(out);
                }
                ++n;
                start = i + 1;
            }
        }
        return "";
    }
}
