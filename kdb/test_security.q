/ Security checks for ONE role's q process. Run: make kdb-test (runs it in each role's container)
/ Env: ROLE, KDBX_DB_USERNAME/KDBX_DB_PASSWORD (this role), OTHER_USER/OTHER_PW (another role's real login).
/ Uses the exact call shape the KDB-X MCP server sends.
role:`$getenv`ROLE; user:getenv`KDBX_DB_USERNAME; pw:getenv`KDBX_DB_PASSWORD; fails:0;
own:(`prices`trades`quotes!`daily_prices`trades`quotes) role;
others:`daily_prices`trades`quotes except own;
chk:{[lbl;ok] -1 $[ok;"PASS ";"FAIL "],lbl; if[not ok;fails+:1]};
err:{[f;x] @[f;x;{`err}]~`err};
T:{ssr[x;"TBL";string own]};                          / put this role's table name into a query template

/ auth: only this role's user may log in
chk["anonymous rejected";err[hopen;`::5000]];
chk["wrong password rejected";err[hopen;`$"::5000:",user,":nope"]];
chk["unknown user rejected";err[hopen;`$"::5000:bob:",pw]];
chk["other role's real login rejected here";err[hopen;`$"::5000:",getenv[`OTHER_USER],":",getenv`OTHER_PW]];
h:hopen`$"::5000:",user,":",pw;

sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}";
sql:{[q] h(sqlCall;q;1000)};
n0:h T"count TBL";

/ isolation: this process only has its own table
chk["tables[] is only ",string own;(enlist own)~h"tables[]"];
{chk["q cannot see ",string x;err[h;"count ",string x]]} each others;
{chk["SQL cannot see ",string x;err[sql;"SELECT * FROM ",string[x]," LIMIT 1"]]} each others;
{chk["no files for ",string x;err[h;"get`:2026.09.29/",string[x],"/.d"]]} each others;

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
chk["creds not readable via .sec.creds";err[h;".sec.creds[]"]];
chk["no hashes in .z.pw (plain lambda, not a projection)";100h=type h".z.pw"];
chk["data unchanged";n0=h T"count TBL"];
chk["no new tables";(enlist own)~h"tables[]"];

-1 $[fails;string[fails]," FAILED";"ALL PASSED"];
exit fails
