/ Security checks for milestone 1. Run: make kdb-test (needs env PW = mcp_ro password)
/ Uses the exact call shape the KDB-X MCP server sends.
pw:getenv`PW; fails:0;
chk:{[lbl;ok] -1 $[ok;"PASS ";"FAIL "],lbl; if[not ok;fails+:1]};
err:{[f;x] @[f;x;{`err}]~`err};

/ auth
chk["anonymous rejected";err[hopen;`::5000]];
chk["wrong password rejected";err[hopen;`$"::5000:mcp_ro:nope"]];
chk["unknown user rejected";err[hopen;`$"::5000:bob:",pw]];
h:hopen`$"::5000:mcp_ro:",pw;

sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}";
sql:{[q] h(sqlCall;q;1000)};
n0:h"count daily_prices";

/ reads
chk["SQL SELECT returns rows";5=(sql"SELECT * FROM daily_prices LIMIT 5")`rowCount];
chk["SQL WITH works";1=(sql"WITH x AS (SELECT * FROM daily_prices) SELECT count(*) AS n FROM x")`rowCount];
chk["string literal with keyword ok";0=(sql"SELECT * FROM daily_prices WHERE name = 'DROP; delete'")`rowCount];
chk["q read works";n0=26100];
chk["MCP version check works";-9h=type h".z.K"];
chk["MCP SQL-loaded check works";h"@[{2< count .s};(::);{0b}]"];
chk["MCP tables listing works";`daily_prices in h"tables[]"];

/ writes and escapes: all must fail
w:("INSERT INTO daily_prices VALUES ('2026-10-01','T001','x',1.0,1)";"DELETE FROM daily_prices";
   "UPDATE daily_prices SET close=0";"CREATE TABLE zz (a INT)";"DROP TABLE daily_prices";
   "SELECT 1; DROP TABLE daily_prices";"SELECT 1 -- x";"SELECT /* x */ 1";"select 1 from daily_prices into zz";
   " drop table daily_prices");
{chk["SQL blocked: ",x;err[sql;x]]}each w;
q:("daily_prices:0#daily_prices";"delete from `daily_prices";"`daily_prices insert first daily_prices";
   "zz:1";"system\"ls\"";"exit 0";"read0`:/run/secrets/kdb_users.txt";"read0`:/etc/hostname";
   ".z.pg:{x}";".s.e\"DROP TABLE daily_prices\"";
   (`.s.e;"DROP TABLE daily_prices");({.s.e x};"DROP TABLE daily_prices");
   ("{r:.s.e x;r}";"DROP TABLE daily_prices";1000));
{chk["q blocked: ",-3!x;err[h;x]]}each q;
chk["data unchanged";n0=h"count daily_prices"];
chk["no new tables";(enlist`daily_prices)~h"tables[]"];

-1 $[fails;string[fails]," FAILED";"ALL PASSED"];
exit fails
