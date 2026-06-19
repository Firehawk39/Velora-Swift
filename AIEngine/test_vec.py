import os
import sys
import struct
import math

# Add the AIEngine root to the Python path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

try:
    from database.db import get_db_connection, VEC_AVAILABLE
except Exception as e:
    print(f"Failed to import database modules: {e}")
    sys.exit(1)

def test_vector_search():
    if not VEC_AVAILABLE:
        print("sqlite-vec is not available. Test skipped.")
        return

    conn = get_db_connection()
    cursor = conn.cursor()
    
    print("Vector Database is active. Creating test data...")
    
    # 1. Clear any old test data
    cursor.execute("DELETE FROM vec_tracks WHERE track_id IN ('test_1', 'test_2', 'test_3')")
    
    # 2. Create 3 fake 512D embeddings
    # We make them distinct to test similarity easily
    # e1 is close to e2, but far from e3
    e1 = [0.1] * 512
    e2 = [0.11] * 512
    e3 = [0.9] * 512
    
    # Serialize to bytes
    b1 = struct.pack(f"{len(e1)}f", *e1)
    b2 = struct.pack(f"{len(e2)}f", *e2)
    b3 = struct.pack(f"{len(e3)}f", *e3)
    
    # 3. Insert into vec_tracks
    cursor.execute("INSERT INTO vec_tracks (track_id, embedding) VALUES (?, ?)", ("test_1", b1))
    cursor.execute("INSERT INTO vec_tracks (track_id, embedding) VALUES (?, ?)", ("test_2", b2))
    cursor.execute("INSERT INTO vec_tracks (track_id, embedding) VALUES (?, ?)", ("test_3", b3))
    conn.commit()
    
    # 4. Perform a nearest-neighbor query for e1
    # We want the 2 closest tracks to e1. It should return test_1 (distance 0) and test_2.
    print("\nQuerying for nearest neighbors of test_1...")
    cursor.execute(
        """
        SELECT track_id, distance
        FROM vec_tracks
        WHERE embedding MATCH ?
        ORDER BY distance
        LIMIT 2
        """,
        (b1,)
    )
    
    results = cursor.fetchall()
    
    for row in results:
        print(f"Found: {row['track_id']} with distance {row['distance']:.4f}")
        
    if len(results) >= 2 and results[0]['track_id'] == 'test_1' and results[1]['track_id'] == 'test_2':
        print("\nSUCCESS! The vector database successfully matched similar embeddings.")
    else:
        print("\nFAILED! The math didn't return the expected results.")
        
    # Clean up
    cursor.execute("DELETE FROM vec_tracks WHERE track_id IN ('test_1', 'test_2', 'test_3')")
    conn.commit()
    conn.close()

if __name__ == "__main__":
    test_vector_search()
