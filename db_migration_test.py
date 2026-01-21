#!/usr/bin/env python3
import pymysql

# Set your credentials here
DB_HOST = "staging.tt-gmbh.de"
DB_PORT = 3306
DB_NAME = "d045f262"
DB_USER = "d045f262"
DB_PASSWORD = "HXBU94bBXu82brJchGbw"
TEST_DB_NAME = f"{DB_NAME}_test"


def main():
    conn = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        autocommit=True,
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            print("Connected.")
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{TEST_DB_NAME}`")
            print(f"Database ready: {TEST_DB_NAME}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
