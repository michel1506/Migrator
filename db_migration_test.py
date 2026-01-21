#!/usr/bin/env python3
import pymysql

# Set your credentials here
DB_HOST = "test-shop.tt-gmbh.de"
DB_PORT = 3306
DB_NAME = "d045ef85"
DB_USER = "d045ef85"
DB_PASSWORD = "2E8P2HMJkj4cLniwXd9m"


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
