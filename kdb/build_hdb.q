/ Write the canonical HDB and the per-role views. Run once: make kdb-hdb
/   /data/hdb/                     one database: <table>_sym files + <date>/<table>/ column files
/   /data/roles/<role>/            hard links to ONE table's files (no data copied); each role's q process loads only this
\l /opt/app/gen_data.q

if[not ()~key `:/data/hdb; -2 "HDB already exists; delete kdb/data to rebuild"; exit 1];
db:`:/data/hdb;
tbls:`daily_prices`trades`quotes;
src:tbls!(daily_prices;trades;quotes);
dates:asc distinct daily_prices`date;

/ .Q.dpfts[db;date;`sym;`tbl;`dom]: save global `tbl (no date column) into db/date/tbl, sorted by sym with p#,
/ enumerating symbols against db/dom. A separate domain per table keeps each role's files self-contained.
wr:{[t;d] t set delete date from select from src[t] where date=d; .Q.dpfts[db;d;`sym;t;`$string[t],"_sym"]};
{[t] wr[t] each dates; -1 "  ",string[t],": ",string count src t} each tbls;

/ roles: role name -> its one table
roles:`prices`trades`quotes!tbls;
link:{[r;t] dst:"/data/roles/",string r;
  system "mkdir -p ",dst;
  system "ln /data/hdb/",string[t],"_sym ",dst,"/";
  {[dst;t;d] system "mkdir -p ",dst,"/",string d; system "cp -al /data/hdb/",string[d],"/",string[t]," ",dst,"/",string[d],"/"}[dst;t] each dates;
  -1 "  role ",string[r]," -> ",string t};
link'[key roles;value roles];
-1 "HDB written: ",string[count dates]," dates";
exit 0
