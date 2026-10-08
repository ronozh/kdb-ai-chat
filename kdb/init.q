/ KDB-X startup: data, SQL interface, security. Run as: q init.q -p 5000
\l gen_data.q
.s.init[];

/ ---- security ----
/ Credentials file (outside the working dir, which reval can read): user:salt:sha1hex(salt,password).
/ Held only inside the .z.pw projection, no global.
.z.pw:{[c;u;p] $[null u;0b;not u in key c;0b;c[u;1]~raze string -33!c[u;0],p]}
  [{(`$x[;0])!1_'x}":"vs'read0 hsym`$getenv`KDB_USERS_FILE];

/ Read-only. reval blocks writes to globals, system calls and file access outside the working dir.
/ KX SQL (.s.e) writes an internal counter, so it fails under reval and under -b (-b is therefore not used).
/ Exception: the MCP server's exact SQL call runs .s.e directly, only for a single SELECT/WITH statement.
/ (Unrestricted .s.e accepts INSERT/CREATE/DROP; it cannot call q functions.)
.sec.sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}";
.sec.isSqlCall:{$[0h<>type x;0b;3<>count x;0b;.sec.sqlCall~x 0]};
.sec.unquote:{[c;s] s where not (s=c)|(sums s=c) mod 2};   / drop c-quoted literals
.sec.readOnly:{[q]
  if[10h<>type q;:0b];
  u:upper .sec.unquote["\"";.sec.unquote["'";q]];
  if[(";" in u) or any((u="-")&next[u]="-")or(u="/")&next[u]="*";:0b];   / single statement, no comments
  w:(" "vs @[u;where not u within "AZ";:;" "]) except enlist"";
  $[not first[w] in ("SELECT";"WITH");0b;
    any w in ("INSERT";"UPDATE";"DELETE";"CREATE";"DROP";"ALTER";"TRUNCATE";"INTO";"MERGE";"REPLACE";"UPSERT";"GRANT");0b;
    1b]};
.sec.trim:{[q] $[10h<>type q;q;{(neg sum mins reverse x in " \t\r\n;")_x}trim q]};   / drop trailing ;
.sec.sql:{[q;n] q:.sec.trim q; if[not .sec.readOnly q;'"read-only: only a single SELECT/WITH statement is allowed"];
  r:.s.e q; `rowCount`data!(count r;.j.j n sublist r)};
/ audit log: one line per remote query
.sec.log:{[k;x] -1 " "sv(string .z.p;string .z.u;k;.Q.s1 x);};
/ like the default handler: a ("fn-as-string";args..) call resolves the string first, all inside reval
.sec.app:{$[(0h=type x)&10h=type first x;(value first x). 1_x;value x]};
.z.pg:{.sec.log["sync";x]; $[.sec.isSqlCall x;.sec.sql . 1_x;reval(.sec.app;enlist x)]};
.z.ps:{.sec.log["async";x]; reval(.sec.app;enlist x)};

/ no HTTP or websocket query paths
.z.ph:{.h.hn["403 Forbidden";`txt;"forbidden"]};
.z.pp:.z.ph;
.z.ws:{neg[.z.w] "forbidden"};

-1 "daily_prices: ",string[count daily_prices]," rows, ",string[count distinct daily_prices`sym]," syms, ",string[min daily_prices`date]," to ",string max daily_prices`date;
