<?php

//   Copyright 2008-2013 Kristopher R Beevers and Internap Network
//   Services Corporation.

//   Permission is hereby granted, free of charge, to any person
//   obtaining a copy of this software and associated documentation files
//   (the "Software"), to deal in the Software without restriction,
//   including without limitation the rights to use, copy, modify, merge,
//   publish, distribute, sublicense, and/or sell copies of the Software,
//   and to permit persons to whom the Software is furnished to do so,
//   subject to the following conditions:

//   The above copyright notice and this permission notice shall be
//   included in all copies or substantial portions of the Software.

//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
//   ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.

// pretty much a direct-to-PHP translation of slog.pm

class slog
{
  protected $path;
  protected $db;

  function __construct($file)
  {
    $this->path = $file;
  }

  function open()
  {
    if(!file_exists($this->path))
      return false;

    $this->db = sqlite3_open($this->path);
    if(!$this->db)
      return false;

    // get metadata
    $res = sqlite3_query($this->db, 'SELECT name, value FROM meta');
    while($row = sqlite3_fetch_array($res))
      $this->meta[$row['name']] = $row['value'];
    return true;
  }

  function create($length, $columns)
  {
    if(count($columns) < 1)
      return false;

    $this->db = sqlite3_open($this->path);
    if(!$this->db)
      return false;

    $this->meta['num_columns'] = count($columns)+1;
    $cols = implode(' TEXT, ', $columns).' TEXT';

    return sqlite3_query($this->db, 'CREATE TABLE meta(name TEXT, value TEXT)') &&
      sqlite3_query($this->db, 'CREATE TABLE logs(timestamp INTEGER, '.$cols.')') &&
      sqlite3_query($this->db, 'CREATE INDEX index_timestamp ON logs(timestamp)') &&
      sqlite3_query($this->db, "INSERT INTO meta VALUES ('length','$length')") &&
      sqlite3_query($this->db, 'INSERT INTO meta VALUES ("num_columns","'.$this->meta['num_columns'].')');
  }

  function current($columns = null)
  {
    $what = !isset($columns) ? '*' : implode(',', $columns);
    $res = sqlite3_query($this->db, 'SELECT '.$what.' FROM logs ORDER BY ROWID DESC LIMIT 1');
    return sqlite3_fetch_array($res);
  }

  function update($dp)
  {
    if(count($dp) != $this->meta['num_columns'])
      return false;

    $ok = true;
    $current = $this->current();
    if($current) {
      $ts = array_shift($dp);
      $cur_ts = array_shift($current);

      // 1. verify that the update ts is newer than the most recent in
      // the db
      if($cur_ts >= $ts)
        return false;

      // 2. check to see if the new datapoint is different than the
      // most recent
      $ok = count($current) ? false : true;
      for($i = 0; $i < count($current); ++$i)
        if($current[$i] != $dp[$i]) {
          $ok = false;
          break;
        }
    }

    if($ok) {
      $cols = '';
      foreach($dp as $p)
        $cols .= "'$p',";
      $cols = substr($cols, 0, strlen($cols)-1);
      if(!sqlite3_query($this->db, "INSERT INTO logs VALUES($ts, $cols)"))
        return false;
    } else {
      // update the file's mtime anyway just so we know it's up to
      // date
      touch($this->path);
    }
    $cur_ts = $ts;

    // 3. delete anything old from the db
    $too_old = $cur_ts - $this->meta['length'];
    return sqlite3_query($this->db, "DELETE FROM logs WHERE timestamp < $too_old");
  }

  // fetch $columns between $start to $end
  // also handle if $start = null or $end = null
  function fetch($start = null, $end = null, $columns = null)
  {
    $what = !isset($columns) ? '*' : implode(',', $columns);
    $ret = array();

    // if there's a start time, get the value at that time first
    if(isset($start))
      array_push($this->value_at_time($start, $columns));

    // now get subsequent entries
    $query = "SELECT $what FROM logs";
    if(isset($start) || isset($end)) {
      $query .= ' WHERE ';
      if(isset($start)) $query .= "timestamp >= $start";
      if(isset($start) && isset($end)) $query .= ' AND ';
      if(isset($end)) $query .= "timestamp <= $end";
    }

    $res = sqlite3_query($this->db, $query);
    while($row = sqlite3_fetch_array($res))
      array_push($ret, $row);
    return $ret;
  }

  // figure out the values of $columns (or all columns if $columns =
  // null) at the given timestamp
  function value_at_time($ts, $columns = null)
  {
    $what = !isset($columns) ? '*' : implode(',', $columns);
    $res = sqlite3_query
      ($this->db, 'SELECT '.$what.' FROM logs WHERE timestamp <= '.
       $ts.' ORDER BY ROWID DESC LIMIT 1');
    return sqlite3_fetch_array($res);
  }

}
