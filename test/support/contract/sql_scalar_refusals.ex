defmodule InfluxElixir.Contract.SQLScalarRefusals do
  @moduledoc """
  The cases of the `*_refusable` tables that `Client.Local` refuses by name instead
  of answering, as `{kind, text}`: the pin of the ratchet in
  `InfluxElixir.Contract.SQLScalar`.

  The pin is a set of cases, not a number of them. A case that is refused now and
  is not listed has regressed; a case that is listed and is answered now has been
  fixed, and moves out of its refusable table into the table of answers (and out of
  the list here). Swapping one for another fails twice, once for each, where a count
  would hold. A real engine refuses none of them.

  To list the cases of a table: run it against `Client.Local`, and keep the ones for
  which `InfluxElixir.Contract.SQLScalar.refusal?/1` holds of the answer.
  """

  @doc "The cases refused of `expressions_values_refusable/0` of `SQLScalarCases`."
  @spec expressions_values() :: [{atom(), binary()}]
  def expressions_values do
    [
      {:sel, "s ~ 's[01]'"},
      {:sel, "s !~ 's[01]'"},
      {:sel, "s ~* 'S1'"},
      {:raw, "SELECT u, coalesce(u, 1) AS a FROM mext ORDER BY time"},
      {:raw, "SELECT u, greatest(u, 3) AS a FROM mext ORDER BY time"},
      {:raw, "SELECT u, least(u, 3) AS a FROM mext ORDER BY time"},
      {:raw, "SELECT u, nullif(u, 5) AS a FROM mext ORDER BY time"},
      {:raw, "SELECT u, CASE WHEN u > 3 THEN u ELSE 0 END AS a FROM mext ORDER BY time"},
      {:raw, "SELECT u, pow(u, 2) AS a FROM mext ORDER BY time"},
      {:sel, "greatest(time, time)"},
      {:sel, "coalesce(time, time)"},
      {:sel, "nullif(time, time)"},
      {:sel, "length(time)"},
      {:sel, "CASE WHEN b THEN time ELSE time END"},
      {:sel, "time || 'a'"},
      {:sel, "CASE time WHEN '2023-11-14T22:13:20Z' THEN 'a' END"}
    ]
  end

  @doc "The cases refused of `expressions_names_refusable/0` of `SQLScalarCases`."
  @spec expressions_names() :: [{atom(), binary()}]
  def expressions_names do
    [
      {:raw, "SELECT CAST(n AS BIGINT UNSIGNED) FROM main WHERE n = 4"}
    ]
  end

  @doc "The cases refused of `functions_values_refusable/0` of `SQLScalarCases`."
  @spec functions_values() :: [{atom(), binary()}]
  def functions_values do
    [
      {:sel, "pow(1.0e300 * 1.0e300, 2.0)"},
      {:sel, "pow(2.0, 1.0e300 * 1.0e300)"},
      {:sel, "pow(2, 1.0e300 * 1.0e300)"},
      {:sel, "pow(length(s), 2)"},
      {:sel, "greatest(length(s), 1)"},
      {:raw, "SELECT log(CAST(n AS DOUBLE), n) AS r FROM main ORDER BY time"},
      {:raw, "SELECT log(CAST(x AS DOUBLE), x) AS r FROM main ORDER BY time"},
      {:raw, "SELECT log(u, u) AS r FROM mext ORDER BY time"}
    ]
  end

  @doc "The cases refused of `errors_refusable/0` of `SQLScalarCases`."
  @spec errors() :: [{atom(), binary()}]
  def errors do
    [
      {:sel, "coalesce(x, s)"},
      {:sel, "coalesce(s, n, x)"},
      {:sel, "nullif(host, n)"},
      {:sel, "greatest(b, n)"},
      {:sel, "least(time, 1)"},
      {:sel, "lower(time)"},
      {:sel, "CASE WHEN b THEN time ELSE 1 END"},
      {:sel, "CASE WHEN b THEN time ELSE 's' END"},
      {:sel, "starts_with(time, 'a')"},
      {:sel, "greatest(1, 'a')"},
      {:sel, "greatest(n, true)"},
      {:sel, "substr('a')"},
      {:sel, "log(x, x, x)"},
      {:sel, "log(s)"},
      {:sel, "log(b)"},
      {:sel, "log(2, s)"},
      {:sel, "greatest(s, n)"},
      {:sel, "least(s, b)"},
      {:sel, "greatest(x, n, s)"},
      {:where, "substr(s) = 'a'"},
      {:where, "log(s) > 1"},
      {:where, "greatest(s, n) = 1"},
      {:order, "substr(s)"},
      {:order, "greatest(s, n)"},
      {:order, "log(s)"},
      {:raw, "SELECT CAST(substr(s) AS INT) FROM main"},
      {:raw, "SELECT substr(s) IS NULL FROM main"},
      {:sel, "log(host, host)"},
      {:sel, "log(s, s)"},
      {:sel, "log(b, b)"},
      {:sel, "CASE WHEN s THEN 1 END"},
      {:sel, "CASE WHEN n > 1 THEN 1 WHEN n > 2 THEN true ELSE 3 END"},
      {:sel, "coalesce(n, s)"},
      {:sel, "coalesce(n, x, s)"},
      {:sel, "coalesce(host, 1)"},
      {:sel, "nullif(n, s)"},
      {:sel, "nullif(s, 1)"},
      {:sel, "nullif(x, s)"},
      {:sel, "time = 'abc'"},
      {:where, "s LIKE n"},
      {:where, "coalesce(n, s) > 1"},
      {:where, "nullif(n, s) > 1"},
      {:where, "time > n"},
      {:where, "time < x"},
      {:order, "coalesce(n, s)"},
      {:order, "nullif(n, s)"},
      {:sel, "x IS UNKNOWN"},
      {:sel, "CASE WHEN time THEN 'b' END"},
      {:sel, "CASE time WHEN 's' THEN 'a' END"},
      {:sel, "CASE time WHEN s THEN 'a' END"},
      {:sel, "CASE s WHEN time THEN 'a' END"},
      {:sel, "CASE host WHEN time THEN 'a' END"},
      {:raw, "replace into m values (1)"},
      {:raw, "select +s from main limit 1"},
      {:raw, "select log('a',NULL) from main"},
      {:raw, "select log(NULL,'a') from main"},
      {:raw, "select log(NULL,host) from main"},
      {:raw, "select log(NULL,time) from main"},
      {:raw, "select log(NULL,true) from main"},
      {:raw, "select log(host,NULL) from main"},
      {:raw, "select log(time,NULL) from main"},
      {:raw, "select log(true,NULL) from main"},
      {:raw, "select starts_with(NULL,time) from main"},
      {:raw, "select starts_with(time,NULL) from main"}
    ]
  end

  @doc "The cases refused of `aggregates_refusable/0` of `SQLCatalogCases`."
  @spec aggregates() :: [{atom(), binary()}]
  def aggregates do
    [
      {:raw, "SELECT sum(i / u) + 'a' AS r FROM mext"},
      {:raw, "SELECT avg(i / u) + 'a' AS r FROM mext"},
      {:raw, "SELECT host, sum(n) AS s FROM main GROUP BY host HAVING sum(n)"},
      {:raw, "SELECT host, sum(n) AS s FROM main GROUP BY host HAVING host"},
      {:raw, "SELECT host, sum(n) AS s FROM main GROUP BY host ORDER BY count(*), host"},
      {:raw, "SELECT n AS a, n AS a FROM main WHERE n < 3"},
      {:raw, "SELECT n a, n a FROM main WHERE n < 3"},
      {:raw, "SELECT n, n FROM main WHERE n < 3"},
      {:raw, "SELECT *, n + 1 AS p FROM main WHERE n = 1"},
      {:raw, "SELECT count(*) FROM main HAVING nosuch > 1"},
      {:raw, "SELECT n + 1 AS a, sum(v) AS s FROM main GROUP BY host"},
      {:raw, "SELECT host || 'x' AS a, sum(v) AS s FROM main GROUP BY region"},
      {:raw, "SELECT host, n, sum(v) FROM main GROUP BY host || 'x'"},
      {:raw, "SELECT host, n, sum(v) FROM main GROUP BY upper(host)"},
      {:raw,
       "SELECT date_bin(interval '1 minute', time) AS t, host, n, sum(v) FROM main GROUP BY date_bin(interval '1 minute', time), host"},
      {:raw,
       "SELECT date_bin(interval '1 day', time) AS t, n, sum(v) FROM main GROUP BY date_bin(interval '1 day', time)"},
      {:raw,
       "SELECT date_bin(interval '1 minute', time) AS t, sum(v) FROM main GROUP BY date_bin(interval '1 minute', time) HAVING region = 'r0'"},
      {:raw, "SELECT host, sum(v) + sum(n) AS t, n FROM main GROUP BY host"},
      {:raw, "SELECT host, first_value(n) AS t, n FROM main GROUP BY host"},
      {:raw, "SELECT host, selector_first(n, time) AS t, n FROM main GROUP BY host"},
      {:raw, "SELECT host, sum(v) * 2 AS t, n FROM main GROUP BY host"},
      {:raw, "SELECT host, approx_median(n) AS t, region FROM main GROUP BY host"},
      {:raw, "SELECT host, array_agg(n) AS t, region FROM main GROUP BY host"},
      {:raw, "SELECT avg(DISTINCT n) + 1 AS r FROM main"},
      {:raw, "select count(distinct n, v) from main"},
      {:raw, "select selector_max(v) from main"},
      {:raw, "select selector_max(v, 'a') from main"},
      {:raw, "select selector_max(v, time + 1) from main"}
    ]
  end

  @doc "The cases refused of `syntax_refusable/0` of `SQLCatalogCases`."
  @spec syntax() :: [{atom(), binary()}]
  def syntax do
    [
      {:raw, "SELECT count(*, 1) FROM main"},
      {:raw, "SELECT n // 2 FROM main"},
      {:raw, "SELECT 'a' ~~ 'a'"},
      {:raw, "SELECT 'a' ~~* 'A'"},
      {:raw, "SELECT 'a' !~~ 'a'"},
      {:raw, "SELECT 'a' !~~* 'b'"},
      {:raw, "SELECT s ~~ 's%' FROM main WHERE n = 1"},
      {:raw, "SELECT current_time IS NOT NULL"},
      {:raw, "SELECT current_date IS NOT NULL"},
      {:raw, "SELECT current_timestamp IS NOT NULL"},
      {:raw, "SELECT current_time() IS NOT NULL"},
      {:raw, "SELECT timestamp '2020-01-01 00:00:00'"},
      {:raw, "SELECT timestamp with time zone '2020-01-01 00:00:00'"},
      {:raw, "SELECT timestamp without time zone '2020-01-01 00:00:00'"},
      {:raw, "SELECT timestamp(3) '2020-01-01 00:00:00'"},
      {:raw, "SELECT timestamp(3) with time zone '2020-01-01'"},
      {:raw, "SELECT timestamptz '2020-01-01'"},
      {:raw, "SELECT date '2020-01-01'"},
      {:raw, "SELECT time '10:00:00'"},
      {:raw, "SELECT time with time zone '10:00:00'"},
      {:raw, "SELECT datetime '2020-01-01 00:00:00'"},
      {:raw, "SELECT time(3) '10:00:00'"},
      {:raw,
       "SELECT n FROM main WHERE time > timestamp with time zone '2023-11-14 22:13:25' AND n = 1"},
      {:raw, "SELECT time - time AS d FROM main WHERE n = 1"},
      {:raw, "SELECT max(time) - min(time) AS d FROM main"},
      {:raw, "SELECT count(*) AS c FROM main WHERE time - time = interval '0'"},
      {:raw, "SELECT time - interval '1 second' AS t FROM main WHERE n = 1"},
      {:raw, "SELECT host on FROM main WHERE n = 1"},
      {:raw, "SELECT host join FROM main WHERE n = 1"},
      {:raw, "SELECT v FROM main WHERE n IN (1 == 1)"},
      {:raw, "SELECT n <=> 1 AS r FROM main ORDER BY time"},
      {:raw, "SELECT n <=> NULL AS r FROM main ORDER BY time"},
      {:raw, "SELECT v FROM main WHERE n <=> NULL"},
      {:raw, "SELECT v FROM main WHERE NOT n <=> 1 ORDER BY time LIMIT 2"},
      {:raw, "SELECT n <=> FROM main"},
      {:raw, "SELECT DISTINCT ALL n FROM main ORDER BY n"},
      {:raw, "SELECT ALL n FROM main UNION ALL SELECT ALL n FROM main ORDER BY n"},
      {:raw, "SELECT * EXCLUDE (n, time) FROM main ORDER BY host, v LIMIT 1"},
      {:raw, "SELECT * EXCLUDE n FROM main ORDER BY time LIMIT 1"},
      {:raw, "SELECT * EXCEPT (n) FROM main ORDER BY time LIMIT 1"},
      {:raw, "SELECT * EXCEPT n FROM main ORDER BY time LIMIT 1"},
      {:raw, "SELECT * REPLACE (n + 1 AS n) FROM main ORDER BY time LIMIT 1"},
      {:raw, "SELECT n FROM (main CROSS JOIN ping) ORDER BY time"},
      {:raw, "SELECT 0x10 AS r FROM main LIMIT 1"},
      {:raw, "SELECT 0x AS r FROM main LIMIT 1"},
      {:raw, "SELECT 0x10 + 1 AS r FROM main LIMIT 1"},
      {:raw, "VALUES (1)"},
      {:raw, "VALUES (1, 'a'), (2, 'b')"},
      {:raw, "SELECT * FROM (VALUES (1), (2)) AS t"},
      {:raw, "VALUES (2), (1) ORDER BY column1 DESC LIMIT 1"},
      {:raw, "SELECT main.n, ping.v FROM main, ping ORDER BY main.n"},
      {:raw, "SELECT n FROM main, ping, mext ORDER BY n"},
      {:raw, "SELECT 1 N'a' z"},
      {:raw, "SELECT 1 X'AB' z"},
      {:raw, "create index i on m (a)"},
      {:raw, "desc 'a'"},
      {:raw, "drop extension a, b"},
      {:raw, "insert into"},
      {:raw, "insert into information_schema.tables values (1)"},
      {:raw, "insert or replace into m values (1)"},
      {:raw, "insert overwrite m values (1)"},
      {:raw, "select 1 union table a"},
      {:raw, "update information_schema.tables set v = 1"},
      {:raw, "update main set v = 1 where zzz.v = 1"},
      {:raw, "update main set v = main.zzz"},
      {:raw, "update main set v = n.zzz"},
      {:raw, "update main set v = zzz.n"},
      {:raw, "update main set v = zzz.n.q"},
      {:raw, "attach database 'd' as e"},
      {:raw, "create trigger t before insert on m"},
      {:raw, "desc 'a b'"},
      {:raw, "grant select () on m to u"},
      {:raw, "merge into m as a using t as b on a.x = b.x when matched then update set x = 1"},
      {:raw, "merge into m using (select 1) as t on true"},
      {:raw,
       "merge into m using t on true when matched then delete when not matched then insert values (1)"},
      {:raw, "merge into m using t on true when not matched then insert (a) values (1)"},
      {:raw, "merge into m using t on x = 1"}
    ]
  end

  @doc "The cases refused of `catalog_refusable/0` of `SQLCatalogCases`."
  @spec catalog() :: [{atom(), binary()}]
  def catalog do
    [
      {:raw, "SHOW COLUMNS FROM system.nosuch"},
      {:raw, "SHOW COLUMNS"},
      {:raw, "SHOW COLUMNS FROM"},
      {:raw, "SHOW COLUMNS FROM main WHERE column_name = 'n'"},
      {:raw, "SHOW COLUMNS FROM \"main\""},
      {:raw, "SHOW SCHEMAS"},
      {:raw, "SHOW TABLES FROM iox"},
      {:raw, "SHOW VARIABLE x"},
      {:raw, "SHOW FULL COLUMNS FROM main"},
      {:raw, "SELECT * FROM system.nosuch"}
    ]
  end
end
