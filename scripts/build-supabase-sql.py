#!/usr/bin/env python3
"""Builds supabase.sql (one paste-able file) from supabase/migrations/*.sql, in order.
Run from the project root:  python3 scripts/build-supabase-sql.py"""
import glob, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files = sorted(glob.glob(os.path.join(root, "supabase", "migrations", "*.sql")))
out = ["-- Will Mac Community: complete database setup (generated from supabase/migrations - do not edit by hand).\n"
       "-- Paste into Supabase > SQL Editor > Run. Safe to run again on an existing project.\n"]
for f in files:
    out.append("\n-- ======================= %s =======================\n" % os.path.basename(f))
    out.append(open(f, encoding="utf-8").read())
open(os.path.join(root, "supabase.sql"), "w", encoding="utf-8").write("".join(out))
print("wrote supabase.sql from", len(files), "migrations")
