extends RefCounted
## Centralized gameplay tuning constants and deterministic ruleset identity.
## All timing values are in seconds. Presentation and input layers read these
## so future tuning only touches this file.

const RULESET_ID: String = "yank-edition-rules-1"
const SAVE_FORMAT_VERSION: int = 1

# --- Simulation ---
const FIXED_STEP: float = 1.0 / 120.0
const MAX_FRAME_DELTA: float = 0.25

# --- Input feel ---
const DAS_SECONDS: float = 0.12
const ARR_SECONDS: float = 0.033

# --- Falling / locking ---
const SOFT_DROP_FACTOR: float = 20.0
const LOCK_DELAY: float = 0.5
const MAX_LOCK_RESETS: int = 15
const LINE_CLEAR_DELAY: float = 0.15

# --- Randomizer / previews ---
const PREVIEW_COUNT: int = 5

# --- Modes ---
const SPRINT_GOAL_LINES: int = 40
const MARATHON_MAX_LEVEL: int = 15
const LINES_PER_LEVEL: int = 10

# --- Scoring (multiplied by level) ---
const SCORE_SINGLE: int = 100
const SCORE_DOUBLE: int = 300
const SCORE_TRIPLE: int = 500
const SCORE_TETRIS: int = 800
const SCORE_TSPIN_ZERO: int = 400
const SCORE_TSPIN_SINGLE: int = 800
const SCORE_TSPIN_DOUBLE: int = 1200
const SCORE_TSPIN_TRIPLE: int = 1600
const SCORE_MINI_ZERO: int = 100
const SCORE_MINI_SINGLE: int = 200
const SCORE_MINI_DOUBLE: int = 400
const COMBO_BONUS_PER_LEVEL: int = 50
const B2B_MULTIPLIER: float = 1.5
const SOFT_DROP_POINTS_PER_CELL: int = 1
const HARD_DROP_POINTS_PER_CELL: int = 2

# --- Perfect clear bonuses (multiplied by level) ---
const PC_SINGLE: int = 800
const PC_DOUBLE: int = 1200
const PC_TRIPLE: int = 1800
const PC_TETRIS: int = 2000
