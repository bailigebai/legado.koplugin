# Third-Party Notices

| Dependency | Exact source revision | License | Vendored runtime files |
| --- | --- | --- | --- |
| [msva/lua-htmlparser](https://github.com/msva/lua-htmlparser) | commit `5ce9a775a345cf458c0388d7288e246bb1b82bff` | LGPL-3.0 with the upstream iOS relinking exception | `legado.koplugin/legado/vendor/htmlparser/` |

The files `init.lua`, `ElementNode.lua`, and `voidelements.lua` come from
`src/htmlparser.lua`, `src/htmlparser/ElementNode.lua`, and
`src/htmlparser/voidelements.lua` at the exact revision above. The two local
`require` keys in `init.lua` are namespaced under `legado.vendor` so the
vendored module obeys the plugin's module namespace; the parser logic is
otherwise unchanged.

The upstream license notice and exception are reproduced verbatim in
`legado.koplugin/legado/vendor/htmlparser/LICENSE`. The complete GNU Lesser
General Public License version 3 terms referenced by that notice are included
alongside it in `legado.koplugin/legado/vendor/htmlparser/COPYING.LESSER`.
