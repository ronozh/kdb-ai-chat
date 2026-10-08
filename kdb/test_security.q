/ kdb security checks: auth and read-only. Run: make kdb-test (needs env KDBX_DB_USERNAME / KDBX_DB_PASSWORD)
/ Uses the exact call shape the KDB-X MCP server sends. Table-level access per user group is enforced
/ in the agent (see doc/06-access-control.md), not here: mcp_ro can read every table.
user:getenv`KDBX_DB_USERNAME; pw:getenv`KDBX_DB_PASSWORD; fails:0;
tbls:`daily_prices`quotes`trades;
chk:{[lbl;ok] -1 $[ok;"PASS ";"FAIL "],lbl; if[not ok;fails+:1]};
err:{[f;x] @[f;x;{`err}]~`err};
T:{ssr[x;"TBL";"daily_prices"]};                       / query templates use daily_prices

/ auth
chk["anonymous rejected";err[hopen;`::5000]];
chk["wrong password rejected";err[hopen;`$"::5000:",user,":nope"]];
chk["unknown user rejected";err[hopen;`$"::5000:bob:",pw]];
h:hopen`$"::5000:",user,":",pw;

sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}";
sql:{[q] h(sqlCall;q;1000)};
n0:h T"count TBL";

chk["all tables loaded";tbls~asc h"tables[]"];
{chk["SQL reads ",string x;1=(sql"SELECT * FROM ",string[x]," LIMIT 1")`rowCount]} each tbls;

/ reads
chk["SQL SELECT returns rows";5=(sql T"SELECT * FROM TBL LIMIT 5")`rowCount];
chk["trailing semicolon ok";2=(sql T"SELECT * FROM TBL LIMIT 2 ;\n")`rowCount];
chk["SQL WITH works";1=(sql T"WITH x AS (SELECT * FROM TBL) SELECT count(*) AS n FROM x")`rowCount];
chk["string literal with keyword ok";0=(sql T"SELECT * FROM TBL WHERE \"sym\" = 'DROP; delete'")`rowCount];
chk["q read works";n0>0];
chk["MCP version check works";-9h=type h".z.K"];
chk["MCP SQL-loaded check works";h"@[{2< count .s};(::);{0b}]"];

/ writes and escapes: all must fail
w:T each ("INSERT INTO TBL SELECT * FROM TBL";"DELETE FROM TBL";
   "UPDATE TBL SET \"sym\"='x'";"CREATE TABLE zz (a INT)";"DROP TABLE TBL";
   "SELECT 1; DROP TABLE TBL";"SELECT 1;;DROP TABLE TBL;";"SELECT 1 -- x";"SELECT /* x */ 1";"select 1 from TBL into zz";
   " drop table TBL";
   "SELECT 1 AS \"a'\" ; DROP TABLE TBL ; SELECT 'b'";            / quote-mixing bypass
   "SELECT 1 AS \"a'\", * INTO zz FROM TBL WHERE \"sym\" <> 'x'";
   "WITH x AS (SELECT 1 AS \"a'\") INSERT INTO TBL SELECT * FROM TBL WHERE 'z'='z'");
{chk["SQL blocked: ",x;err[sql;x]]}each w;
q:(T each ("TBL:0#TBL";"delete from `TBL";"`TBL insert first TBL";"zz:1";"system\"ls\"";"exit 0";
   "read0`:/run/secrets/kdb_users.txt";"read0`:/etc/hostname";".z.pg:{x}";".s.e\"DROP TABLE TBL\"";
   "`:2026.09.29/TBL/sym set 0#`";"get`:../hdb/2026.09.29/TBL/.d")),
   ((`.s.e;T"DROP TABLE TBL");({.s.e x};T"DROP TABLE TBL");("{r:.s.e x;r}";T"DROP TABLE TBL";1000));
{chk["q blocked: ",-3!x;err[h;x]]}each q;
chk["own file read ok (inside working dir)";0<count h T"get`:2026.09.29/TBL/.d"];
chk["lambda row limit blocked";err[h;(sqlCall;T"SELECT 1 FROM TBL";{system"ls";0})]];
/ KX SQL q-escapes must never reach .s.e (they run arbitrary q outside reval). Benign probes.
chk["SQL q-escape qt() blocked";err[sql;"SELECT * FROM qt('([]a:1 2)')"]];
chk["SQL q-escape q() blocked";err[sql;"SELECT q('J';'count';\"sym\") FROM TBL"]];
chk["SQL q-escape set no global";err[sql;"SELECT * FROM qt('([]x:enlist `zzprobe set 1)')"]];
chk["SQL q-escape qt tab blocked";err[sql;"SELECT * FROM qt\t('([]x:enlist `zzprobe set 1)')"]];
chk["SQL q-escape qt newline blocked";err[sql;"SELECT * FROM qt\n('([]x:enlist `zzprobe set 1)')"]];
chk["SQL q-escape qt 2-space blocked";err[sql;"SELECT * FROM qt  ('([]x:enlist `zzprobe set 1)')"]];
chk["SQL dotted .s.F blocked";err[sql;"SELECT * FROM .s.F('t';'x')"]];
chk["no zzprobe global written";err[h;"zzprobe"]];
chk["creds not readable via .sec.creds";err[h;".sec.creds[]"]];
chk["no hashes in .z.pw (plain lambda, not a projection)";100h=type h".z.pw"];
chk["data unchanged";n0=h T"count TBL"];
chk["no new tables";tbls~asc h"tables[]"];

-1 $[fails;string[fails]," FAILED";"ALL PASSED"];
exit fails
