/ Write daily_prices to disk as a date-partitioned HDB (historical database). Run once: make kdb-hdb
/ Layout: /hdb/sym (symbol list) + /hdb/<date>/daily_prices/<one file per column>
\l /opt/app/gen_data.q

db:`:/hdb;
if[not ()~key ` sv db,`sym; -2 "HDB already exists in /hdb; delete kdb/hdb to rebuild"; exit 1];

src:daily_prices;
/ .Q.dpft[db;date;`sym;`name] saves global `name` (without the date column) into db/date/name,
/ enumerates symbol columns against db/sym, sorts by sym and applies the parted (p#) attribute
{[d] daily_prices::delete date from select from src where date=d; .Q.dpft[db;d;`sym;`daily_prices]} each distinct src`date;

-1 "HDB written: ",string[count distinct src`date]," date partitions, ",string[count src]," rows";
exit 0
