import sqlite3
try:
    import sqlite_vec
    VEC_AVAILABLE = True
except ImportError:
    VEC_AVAILABLE = False
    print("WARNING: sqlite_vec not installed. Vector search will be disabled.")
from core.config import settings

def get_db_connection():
    settings.DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(settings.DATABASE_PATH), check_same_thread=False)
    
    if VEC_AVAILABLE:
        try:
            conn.enable_load_extension(True)
            sqlite_vec.load(conn)
            conn.enable_load_extension(False)
        except Exception as e:
            print(f"Failed to load sqlite_vec extension: {e}")

    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """Initialize the database tables if they don't exist."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Create the telemetry table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            event_type TEXT NOT NULL,
            track_id TEXT,
            context TEXT
        )
    ''')
    
    # Create the tracks table for audio embeddings and features
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS tracks (
            track_id TEXT PRIMARY KEY,
            bpm REAL,
            key TEXT,
            danceability REAL,
            embedding BLOB
        )
    ''')
    
    if VEC_AVAILABLE:
        try:
            # Create the virtual table for fast ANN vector search using sqlite-vec
            cursor.execute('''
                CREATE VIRTUAL TABLE IF NOT EXISTS vec_tracks USING vec0(
                    +track_id TEXT,
                    embedding float[512]
                )
            ''')
        except Exception as e:
            print(f"Failed to create vec_tracks virtual table: {e}")
            
    conn.commit()
    conn.close()

# Initialize on module import
init_db()
