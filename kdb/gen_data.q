/ Simulated daily prices for 100 fictional tickers. Deterministic (fixed seed).
\S 42

daily_prices:{[]
  dates:d where 1<(d:2025.10.01+til 365) mod 7;   / weekdays only (2000.01.01 was a Saturday)
  syms:`$"T",/:-3#'"00",/:string 1+til 100;
  / fictional names: prefix x suffix combos
  pre:("Acme";"Borealis";"Cobalt";"Dunmore";"Ember";"Fjord";"Granite";"Halcyon";"Ironwood";"Juniper");
  suf:("Analytics";"Biotech";"Capital";"Dynamics";"Energy";"Foods";"Holdings";"Logistics";"Materials";"Systems");
  names:`$raze pre,/:\:" ",/:suf;
  n:count dates;
  randn:{[k] sqrt[-2*log 1-k?1f]*cos 2*acos[-1]*k?1f};   / standard normal (Box-Muller)
  start:10+100?490f;                                      / start price 10-500
  / geometric random walk, ~2% daily vol, rounded to cents
  closes:{[n;rn;s] 0.01*floor 0.5+100*s*exp sums 0f,(n-1)#0.02*rn n}[n;randn]each start;
  vols:100000+(100*n)?5000000;
  `date`sym xasc ([] date:raze 100#enlist dates; sym:raze n#'syms; name:raze n#'names; close:raze closes; volume:vols)
  }[];

/ Intraday trades and quotes around each day's close (generated after daily_prices, so its values are unchanged).
randn:{[k] sqrt[-2*log 1-k?1f]*cos 2*acos[-1]*k?1f};
intraday:{[k] i:where count[daily_prices]#k;      / each daily row repeated k times
  ([] date:daily_prices[`date] i; sym:daily_prices[`sym] i; ref:daily_prices[`close] i;
      time:09:30:00.000+`time$(count i)?23400000)};   / random time in 09:30-16:00

trades:`date`sym`time xasc select date, sym, time,
  price:0.01*floor 0.5+100*ref*1+0.005*randn count i,
  size:100*1+(count i)?50 from intraday 20;

quotes:`date`sym`time xasc select date, sym, time, bid, ask:bid+spread, bsize, asize from
  update bid:0.01*floor 100*(ref*1+0.005*randn count i)-spread%2 from
  update spread:0.01*1+(count i)?5, bsize:100*1+(count i)?20, asize:100*1+(count i)?20 from intraday 40;
delete ref from `trades; delete ref from `quotes;
