/**
 * JSONL Transaction Log (Blockchain-style)
 *
 * Each portfolio has a dedicated JSONL file tracking all transactions.
 * Current holdings are calculated by parsing the transaction log.
 *
 * Transaction Types:
 *   - GENESIS:    Initial portfolio creation
 *   - CHECKPOINT: Summation of all positions (used when rotating logs)
 *   - BUY:        Purchase shares
 *   - SELL:       Sell shares
 *   - FLIP:       Flip position (YES<->NO, UP<->DOWN)
 *   - RESOLVE:    Market resolved, position closed
 *
 * File Structure:
 *   portfolios/<portfolio_id>.jsonl     - Active transaction log
 *   portfolios/archive/<portfolio_id>_<timestamp>.jsonl - Archived logs
 *
 * Archive Trigger: File size >= 1MB
 */

const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORTFOLIOS_DIR = path.join(__dirname, '..', 'portfolios');
const ARCHIVE_DIR = path.join(PORTFOLIOS_DIR, 'archive');
const MAX_LOG_SIZE = 1024 * 1024; // 1MB

// Transaction types
const TX_TYPE = {
    GENESIS: 'GENESIS',
    CHECKPOINT: 'CHECKPOINT',
    BUY: 'BUY',
    SELL: 'SELL',
    FLIP: 'FLIP',
    RESOLVE: 'RESOLVE',
    ADJUST: 'ADJUST' // For price/confidence updates
};

/**
 * Generate a unique transaction ID
 */
function generateTxId() {
    const timestamp = Date.now().toString(36);
    const random = crypto.randomBytes(4).toString('hex');
    return `tx_${timestamp}_${random}`;
}

/**
 * Generate hash of previous transaction for chain integrity
 */
function hashTransaction(tx) {
    const data = JSON.stringify(tx);
    return crypto.createHash('sha256').update(data).digest('hex').substring(0, 16);
}

/**
 * Get the log file path for a portfolio
 */
function getLogPath(portfolioId) {
    return path.join(PORTFOLIOS_DIR, `${portfolioId}.jsonl`);
}

/**
 * Ensure directories exist
 */
async function ensureDirectories() {
    await fs.mkdir(PORTFOLIOS_DIR, { recursive: true });
    await fs.mkdir(ARCHIVE_DIR, { recursive: true });
}

/**
 * Get file size in bytes
 */
async function getFileSize(filePath) {
    try {
        const stats = await fs.stat(filePath);
        return stats.size;
    } catch (error) {
        if (error.code === 'ENOENT') return 0;
        throw error;
    }
}

/**
 * Read all transactions from a JSONL file
 */
async function readTransactions(filePath) {
    try {
        const content = await fs.readFile(filePath, 'utf8');
        const lines = content.trim().split('\n').filter(line => line.trim());
        return lines.map(line => JSON.parse(line));
    } catch (error) {
        if (error.code === 'ENOENT') return [];
        throw error;
    }
}

/**
 * Append a transaction to the log
 */
async function appendTransaction(portfolioId, tx) {
    await ensureDirectories();
    const logPath = getLogPath(portfolioId);

    // Check if rotation needed before appending
    const size = await getFileSize(logPath);
    if (size >= MAX_LOG_SIZE) {
        await rotateLog(portfolioId);
    }

    // Get last transaction hash for chain integrity
    const transactions = await readTransactions(logPath);
    const lastTx = transactions[transactions.length - 1];
    const prevHash = lastTx ? hashTransaction(lastTx) : '0000000000000000';

    // Complete the transaction
    const fullTx = {
        id: generateTxId(),
        timestamp: new Date().toISOString(),
        prevHash,
        ...tx
    };

    // Append to file
    await fs.appendFile(logPath, JSON.stringify(fullTx) + '\n');

    return fullTx;
}

/**
 * Rotate log file to archive
 */
async function rotateLog(portfolioId) {
    await ensureDirectories();
    const logPath = getLogPath(portfolioId);

    // Check if file exists
    const exists = await getFileSize(logPath) > 0;
    if (!exists) return;

    // Calculate current state before archiving
    const state = await calculateState(portfolioId);

    // Archive current log
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const archivePath = path.join(ARCHIVE_DIR, `${portfolioId}_${timestamp}.jsonl`);
    await fs.rename(logPath, archivePath);

    // Create new log with CHECKPOINT entries
    const checkpointTx = {
        type: TX_TYPE.CHECKPOINT,
        description: `Checkpoint from archived log: ${path.basename(archivePath)}`,
        positions: state.positions,
        realized: state.realized,
        unrealized: state.unrealized
    };

    await appendTransaction(portfolioId, checkpointTx);

    console.log(`Rotated ${portfolioId} log to ${archivePath}`);
    return archivePath;
}

/**
 * Calculate current state from transaction log
 */
async function calculateState(portfolioId) {
    const logPath = getLogPath(portfolioId);
    const transactions = await readTransactions(logPath);

    // Initialize state
    const state = {
        portfolioId,
        positions: {},  // positionId -> { shares, avgEntry, cost, ... }
        realized: 0,
        unrealized: 0,
        transactionCount: transactions.length
    };

    // Process each transaction
    for (const tx of transactions) {
        switch (tx.type) {
            case TX_TYPE.GENESIS:
                // Initialize portfolio metadata
                state.name = tx.name;
                state.color = tx.color;
                state.status = tx.status || 'active';
                break;

            case TX_TYPE.CHECKPOINT:
                // Restore state from checkpoint
                state.positions = { ...tx.positions };
                state.realized = tx.realized;
                state.unrealized = tx.unrealized;
                break;

            case TX_TYPE.BUY:
                if (!state.positions[tx.positionId]) {
                    state.positions[tx.positionId] = {
                        id: tx.positionId,
                        market: tx.market,
                        position: tx.position,
                        shares: 0,
                        totalCost: 0,
                        avgEntry: 0,
                        current: tx.price,
                        confidence: tx.confidence || 50,
                        action: 'hold',
                        reason: tx.reason || ''
                    };
                }
                const buyPos = state.positions[tx.positionId];
                const newShares = buyPos.shares + tx.shares;
                const newCost = buyPos.totalCost + (tx.shares * tx.price);
                buyPos.shares = newShares;
                buyPos.totalCost = newCost;
                buyPos.avgEntry = newCost / newShares;
                buyPos.current = tx.price;
                if (tx.confidence) buyPos.confidence = tx.confidence;
                if (tx.action) buyPos.action = tx.action;
                if (tx.reason) buyPos.reason = tx.reason;
                break;

            case TX_TYPE.SELL:
                if (state.positions[tx.positionId]) {
                    const sellPos = state.positions[tx.positionId];
                    const sellShares = Math.min(tx.shares, sellPos.shares);
                    const costBasis = sellPos.avgEntry * sellShares;
                    const proceeds = tx.price * sellShares;
                    const pnl = proceeds - costBasis;

                    sellPos.shares -= sellShares;
                    sellPos.totalCost -= costBasis;
                    state.realized += pnl;

                    if (sellPos.shares <= 0) {
                        sellPos.action = 'closed';
                        sellPos.reason = tx.reason || 'Position sold';
                        sellPos.exit = tx.price;
                    }
                }
                break;

            case TX_TYPE.FLIP:
                if (state.positions[tx.positionId]) {
                    const flipPos = state.positions[tx.positionId];
                    // Flip direction
                    if (flipPos.position === 'YES') flipPos.position = 'NO';
                    else if (flipPos.position === 'NO') flipPos.position = 'YES';
                    else if (flipPos.position === 'UP') flipPos.position = 'DOWN';
                    else if (flipPos.position === 'DOWN') flipPos.position = 'UP';

                    flipPos.avgEntry = tx.price;
                    flipPos.current = tx.price;
                    flipPos.action = 'hold';
                    flipPos.reason = tx.reason || 'Position flipped';
                }
                break;

            case TX_TYPE.RESOLVE:
                if (state.positions[tx.positionId]) {
                    const resolvePos = state.positions[tx.positionId];
                    const resolvePnl = (tx.outcome ? 1 : 0) * resolvePos.shares - resolvePos.totalCost;
                    state.realized += resolvePnl;
                    resolvePos.action = 'closed';
                    resolvePos.reason = `Resolved: ${tx.outcome ? 'WIN' : 'LOSS'}`;
                    resolvePos.exit = tx.outcome ? 1 : 0;
                    resolvePos.shares = 0;
                }
                break;

            case TX_TYPE.ADJUST:
                if (state.positions[tx.positionId]) {
                    const adjPos = state.positions[tx.positionId];
                    if (tx.current !== undefined) adjPos.current = tx.current;
                    if (tx.confidence !== undefined) adjPos.confidence = tx.confidence;
                    if (tx.action !== undefined) adjPos.action = tx.action;
                    if (tx.reason !== undefined) adjPos.reason = tx.reason;
                }
                break;
        }
    }

    // Calculate unrealized P/L
    state.unrealized = 0;
    Object.values(state.positions).forEach(pos => {
        if (pos.shares > 0 && pos.action !== 'closed') {
            const currentValue = pos.current * pos.shares;
            const costBasis = pos.totalCost;
            pos.pl = currentValue - costBasis;
            state.unrealized += pos.pl;
        } else {
            pos.pl = 0;
        }
    });

    return state;
}

/**
 * Initialize a new portfolio with GENESIS transaction
 */
async function initPortfolio(portfolioId, metadata) {
    await ensureDirectories();
    const logPath = getLogPath(portfolioId);

    // Check if already exists
    const exists = await getFileSize(logPath) > 0;
    if (exists) {
        throw new Error(`Portfolio ${portfolioId} already exists`);
    }

    const genesisTx = {
        type: TX_TYPE.GENESIS,
        portfolioId,
        name: metadata.name,
        color: metadata.color,
        status: metadata.status || 'active',
        description: metadata.description || `Portfolio ${portfolioId} created`
    };

    return await appendTransaction(portfolioId, genesisTx);
}

/**
 * Record a BUY transaction
 */
async function recordBuy(portfolioId, { positionId, market, position, shares, price, confidence, action, reason }) {
    return await appendTransaction(portfolioId, {
        type: TX_TYPE.BUY,
        positionId,
        market,
        position,
        shares,
        price,
        confidence,
        action: action || 'hold',
        reason: reason || ''
    });
}

/**
 * Record a SELL transaction
 */
async function recordSell(portfolioId, { positionId, shares, price, reason }) {
    return await appendTransaction(portfolioId, {
        type: TX_TYPE.SELL,
        positionId,
        shares,
        price,
        reason: reason || 'Position sold'
    });
}

/**
 * Record a FLIP transaction
 */
async function recordFlip(portfolioId, { positionId, price, reason }) {
    return await appendTransaction(portfolioId, {
        type: TX_TYPE.FLIP,
        positionId,
        price,
        reason: reason || 'Position flipped'
    });
}

/**
 * Record a RESOLVE transaction
 */
async function recordResolve(portfolioId, { positionId, outcome, reason }) {
    return await appendTransaction(portfolioId, {
        type: TX_TYPE.RESOLVE,
        positionId,
        outcome, // true = YES/UP won, false = NO/DOWN won
        reason: reason || `Market resolved: ${outcome ? 'YES' : 'NO'}`
    });
}

/**
 * Record an ADJUST transaction (price/confidence update)
 */
async function recordAdjust(portfolioId, { positionId, current, confidence, action, reason }) {
    return await appendTransaction(portfolioId, {
        type: TX_TYPE.ADJUST,
        positionId,
        current,
        confidence,
        action,
        reason
    });
}

/**
 * Verify chain integrity by checking hashes
 */
async function verifyChain(portfolioId) {
    const logPath = getLogPath(portfolioId);
    const transactions = await readTransactions(logPath);

    if (transactions.length === 0) {
        return { valid: true, errors: [], transactionCount: 0 };
    }

    const errors = [];

    // Check first transaction has zero prevHash
    if (transactions[0].prevHash !== '0000000000000000') {
        errors.push(`First transaction should have zero prevHash`);
    }

    // Check chain integrity
    for (let i = 1; i < transactions.length; i++) {
        const prev = transactions[i - 1];
        const curr = transactions[i];
        const expectedHash = hashTransaction(prev);

        if (curr.prevHash !== expectedHash) {
            errors.push(`Chain broken at transaction ${i}: expected ${expectedHash}, got ${curr.prevHash}`);
        }
    }

    return {
        valid: errors.length === 0,
        errors,
        transactionCount: transactions.length
    };
}

/**
 * Audit: Verify checkpoint matches calculated state from archive
 */
async function auditCheckpoint(portfolioId, archivePath) {
    // Calculate state from archive
    const archiveTxs = await readTransactions(archivePath);

    const archiveState = {
        positions: {},
        realized: 0
    };

    // Replay archive transactions (simplified - same logic as calculateState)
    for (const tx of archiveTxs) {
        if (tx.type === TX_TYPE.CHECKPOINT) {
            archiveState.positions = { ...tx.positions };
            archiveState.realized = tx.realized;
        } else if (tx.type === TX_TYPE.BUY) {
            if (!archiveState.positions[tx.positionId]) {
                archiveState.positions[tx.positionId] = {
                    shares: 0, totalCost: 0, avgEntry: 0
                };
            }
            const pos = archiveState.positions[tx.positionId];
            pos.shares += tx.shares;
            pos.totalCost += tx.shares * tx.price;
            pos.avgEntry = pos.totalCost / pos.shares;
        } else if (tx.type === TX_TYPE.SELL) {
            if (archiveState.positions[tx.positionId]) {
                const pos = archiveState.positions[tx.positionId];
                const costBasis = pos.avgEntry * tx.shares;
                archiveState.realized += (tx.price * tx.shares) - costBasis;
                pos.shares -= tx.shares;
                pos.totalCost -= costBasis;
            }
        }
    }

    // Get first checkpoint in current log
    const currentTxs = await readTransactions(getLogPath(portfolioId));
    const checkpoint = currentTxs.find(tx => tx.type === TX_TYPE.CHECKPOINT);

    if (!checkpoint) {
        return { valid: false, error: 'No checkpoint found in current log' };
    }

    // Compare
    const errors = [];

    if (Math.abs(checkpoint.realized - archiveState.realized) > 0.01) {
        errors.push(`Realized P/L mismatch: checkpoint=${checkpoint.realized}, archive=${archiveState.realized}`);
    }

    // Compare positions
    for (const [posId, pos] of Object.entries(checkpoint.positions)) {
        const archivePos = archiveState.positions[posId];
        if (!archivePos) {
            errors.push(`Position ${posId} in checkpoint but not in archive`);
        } else if (Math.abs(pos.shares - archivePos.shares) > 0.001) {
            errors.push(`Position ${posId} shares mismatch: checkpoint=${pos.shares}, archive=${archivePos.shares}`);
        }
    }

    return {
        valid: errors.length === 0,
        errors,
        archiveFile: path.basename(archivePath)
    };
}

/**
 * List all portfolios
 */
async function listPortfolios() {
    await ensureDirectories();
    const files = await fs.readdir(PORTFOLIOS_DIR);
    return files
        .filter(f => f.endsWith('.jsonl') && !f.includes('_'))
        .map(f => f.replace('.jsonl', ''));
}

/**
 * List archived logs for a portfolio
 */
async function listArchives(portfolioId) {
    await ensureDirectories();
    const files = await fs.readdir(ARCHIVE_DIR);
    return files
        .filter(f => f.startsWith(`${portfolioId}_`) && f.endsWith('.jsonl'))
        .sort();
}

/**
 * Get transaction log stats
 */
async function getLogStats(portfolioId) {
    const logPath = getLogPath(portfolioId);
    const size = await getFileSize(logPath);
    const transactions = await readTransactions(logPath);
    const archives = await listArchives(portfolioId);

    return {
        portfolioId,
        currentLogSize: size,
        currentLogSizeHuman: `${(size / 1024).toFixed(2)} KB`,
        maxLogSize: MAX_LOG_SIZE,
        percentFull: ((size / MAX_LOG_SIZE) * 100).toFixed(1),
        transactionCount: transactions.length,
        archiveCount: archives.length,
        archives
    };
}

module.exports = {
    TX_TYPE,
    initPortfolio,
    recordBuy,
    recordSell,
    recordFlip,
    recordResolve,
    recordAdjust,
    calculateState,
    rotateLog,
    verifyChain,
    auditCheckpoint,
    listPortfolios,
    listArchives,
    getLogStats,
    readTransactions,
    PORTFOLIOS_DIR,
    ARCHIVE_DIR
};
