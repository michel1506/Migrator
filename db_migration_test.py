#!/usr/bin/env python3
import pymysql

# Set your credentials here
DB_HOST = "staging.tt-gmbh.de"
DB_PORT = 3306
DB_NAME = "d045f262"
DB_USER = "d045f262"
DB_PASSWORD = "HXBU94bBXu82brJchGbw"


def main():
    conn = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            print("Connected.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
