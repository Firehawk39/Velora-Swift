import sqlite3
from core.config import settings

def get_db_connection():
    settings.DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(settings.DATABASE_PATH), check_same_thread=False)
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
    
    conn.commit()
    conn.close()

# Initialize on module import
init_db()
