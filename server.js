/**
 * Praescientia API Server
 *
 * Express server with JSONL blockchain-style transaction logging.
 * Each portfolio has a dedicated JSONL file tracking all transactions.
 *
 * Usage:
 *   npm install
 *   node server.js
 *
 * Endpoints:
 *   GET  /api/portfolios              - Get all portfolio states
 *   GET  /api/portfolios/:id          - Get specific portfolio state
 *   GET  /api/portfolios/:id/logs     - Get transaction log stats
 *   GET  /api/portfolios/:id/txs      - Get raw transactions
 *   POST /api/portfolios/:id/init     - Initialize a new portfolio
 *   POST /api/trades                  - Execute trades
 *   POST /api/reset                   - Reset all portfolios to defaults
 *   GET  /api/audit/:id               - Audit portfolio chain integrity
 */

const express = require('express');
const path = require('path');
const txlog = require('./lib/txlog');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());
app.use(express.static(__dirname));

// Default portfolio definitions (for initialization)
const DEFAULT_PORTFOLIOS = {
    daily: {
        name: 'Daily (Jan 7)',
        color: '#4dabf7',
        status: 'closed',
        positions: [
            { id: 'd1', market: 'BTC Up/Down Jan 7', position: 'UP', shares: 26, price: 0.575, confidence: 0, action: 'closed', reason: 'Market resolved' },
            { id: 'd2', market: 'ETH Up/Down Jan 7', position: 'UP', shares: 24, price: 0.62, confidence: 0, action: 'closed', reason: 'Market resolved' },
            { id: 'd3', market: 'SOL Up/Down Jan 7', position: 'DOWN', shares: 26, price: 0.38, confidence: 0, action: 'closed', reason: 'Market resolved' },
            { id: 'd4', market: 'SPX Up/Down Jan 7', position: 'DOWN', shares: 25, price: 0.395, confidence: 0, action: 'closed', reason: 'Market resolved' },
        ]
    },
    weekly: {
        name: 'Weekly (Jan 6-12)',
        color: '#da77f2',
        status: 'active',
        positions: [
            { id: 'w1', market: 'BTC hits $100k', position: 'NO', shares: 115, price: 0.87, confidence: 85, action: 'hold', reason: 'High confidence, near max profit' },
            { id: 'w2', market: 'ETH dips to $3k', position: 'NO', shares: 95, price: 0.84, confidence: 80, action: 'hold', reason: 'Strong support above $3k' },
            { id: 'w3', market: 'BTC dips to $88k', position: 'NO', shares: 90, price: 0.78, confidence: 65, action: 'sell', reason: 'BTC weakness - consider taking profit' },
            { id: 'w4', market: 'ETH hits $3.4k', position: 'NO', shares: 89, price: 0.996, confidence: 90, action: 'hold', reason: 'Already flipped, ride to resolution' },
            { id: 'w5', market: 'BTC hits $96k', position: 'NO', shares: 80, price: 0.996, confidence: 85, action: 'hold', reason: 'Already flipped, ride to resolution' },
            { id: 'w6', market: 'SOL hits $150', position: 'NO', shares: 112, price: 0.71, confidence: 75, action: 'sell', reason: 'SOL recovering - lock in gains' },
        ]
    },
    contrarian: {
        name: 'Contrarian (2026)',
        color: '#ff922b',
        status: 'pending',
        positions: [
            { id: 'c1', market: 'US Recession 2026', position: 'YES', shares: 235, price: 0.255, confidence: 70, action: 'buy', reason: 'Sahm Rule triggered - add to position' },
            { id: 'c2', market: 'Fed Rate Hike 2026', position: 'YES', shares: 175, price: 0.115, confidence: 55, action: 'hold', reason: 'Wait for inflation data' },
            { id: 'c3', market: 'Fed Emergency Cut', position: 'YES', shares: 154, price: 0.130, confidence: 60, action: 'hold', reason: 'Tail risk position - hold' },
        ]
    }
};

/**
 * Initialize a portfolio with default positions
 */
async function initializePortfolio(portfolioId) {
    const def = DEFAULT_PORTFOLIOS[portfolioId];
    if (!def) throw new Error(`Unknown portfolio: ${portfolioId}`);

    // Create genesis transaction
    await txlog.initPortfolio(portfolioId, {
        name: def.name,
        color: def.color,
        status: def.status,
        description: `Initialized ${def.name} portfolio`
    });

    // Record initial positions as BUY transactions
    for (const pos of def.positions) {
        await txlog.recordBuy(portfolioId, {
            positionId: pos.id,
            market: pos.market,
            position: pos.position,
            shares: pos.shares,
            price: pos.price,
            confidence: pos.confidence,
            action: pos.action,
            reason: pos.reason
        });
    }

    console.log(`Initialized portfolio: ${portfolioId}`);
}

/**
 * Get portfolio state in dashboard-compatible format
 */
async function getPortfolioForDashboard(portfolioId) {
    const state = await txlog.calculateState(portfolioId);
    const def = DEFAULT_PORTFOLIOS[portfolioId] || {};

    // Convert to dashboard format
    const positions = Object.values(state.positions).map(pos => ({
        id: pos.id,
        market: pos.market,
        position: pos.position,
        entry: pos.avgEntry,
        current: pos.current,
        cost: pos.totalCost,
        pl: pos.pl || 0,
        confidence: pos.confidence || 50,
        action: pos.action || 'hold',
        reason: pos.reason || '',
        exit: pos.exit
    }));

    // Calculate starting value from initial buys
    const starting = positions.reduce((sum, p) => sum + (p.entry * (p.cost / p.entry)), 0);

    return {
        name: state.name || def.name,
        color: state.color || def.color,
        starting: starting || def.positions?.reduce((s, p) => s + p.shares * p.price, 0) || 0,
        realized: state.realized,
        unrealized: state.unrealized,
        status: state.status || 'active',
        positions,
        timeline: [
            { date: '2026-01-06', value: starting },
            { date: '2026-01-07', value: starting + state.realized + state.unrealized }
        ]
    };
}

// ============================================================
// API ENDPOINTS
// ============================================================

// GET /api/portfolios - Get all portfolio states
app.get('/api/portfolios', async (req, res) => {
    try {
        const portfolioIds = await txlog.listPortfolios();

        // If no portfolios exist, initialize defaults
        if (portfolioIds.length === 0) {
            for (const id of Object.keys(DEFAULT_PORTFOLIOS)) {
                await initializePortfolio(id);
            }
        }

        const portfolios = {};
        const ids = portfolioIds.length > 0 ? portfolioIds : Object.keys(DEFAULT_PORTFOLIOS);

        for (const id of ids) {
            portfolios[id] = await getPortfolioForDashboard(id);
        }

        res.json({
            success: true,
            data: portfolios,
            lastUpdated: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error loading portfolios:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// GET /api/portfolios/:id - Get specific portfolio state
app.get('/api/portfolios/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const portfolio = await getPortfolioForDashboard(id);
        res.json({ success: true, data: portfolio });
    } catch (error) {
        console.error('Error loading portfolio:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// GET /api/portfolios/:id/logs - Get transaction log stats
app.get('/api/portfolios/:id/logs', async (req, res) => {
    try {
        const { id } = req.params;
        const stats = await txlog.getLogStats(id);
        res.json({ success: true, data: stats });
    } catch (error) {
        console.error('Error getting log stats:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// GET /api/portfolios/:id/txs - Get raw transactions
app.get('/api/portfolios/:id/txs', async (req, res) => {
    try {
        const { id } = req.params;
        const logPath = path.join(txlog.PORTFOLIOS_DIR, `${id}.jsonl`);
        const transactions = await txlog.readTransactions(logPath);
        res.json({
            success: true,
            data: transactions,
            count: transactions.length
        });
    } catch (error) {
        console.error('Error getting transactions:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// POST /api/portfolios/:id/init - Initialize a new portfolio
app.post('/api/portfolios/:id/init', async (req, res) => {
    try {
        const { id } = req.params;
        await initializePortfolio(id);
        const portfolio = await getPortfolioForDashboard(id);
        res.json({ success: true, data: portfolio });
    } catch (error) {
        console.error('Error initializing portfolio:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// POST /api/trades - Execute trades
app.post('/api/trades', async (req, res) => {
    try {
        const { actions } = req.body; // { buy: [...], sell: [...], flip: [...] }
        const results = { bought: 0, sold: 0, flipped: 0, transactions: [] };

        // Get current states to look up position details
        const portfolioIds = await txlog.listPortfolios();
        const states = {};
        for (const id of portfolioIds) {
            states[id] = await txlog.calculateState(id);
        }

        // Process SELL actions
        for (const pos of (actions.sell || [])) {
            // Find which portfolio this position belongs to
            for (const [portfolioId, state] of Object.entries(states)) {
                if (state.positions[pos.id]) {
                    const position = state.positions[pos.id];
                    const tx = await txlog.recordSell(portfolioId, {
                        positionId: pos.id,
                        shares: position.shares,
                        price: position.current,
                        reason: 'User executed sell'
                    });
                    results.sold++;
                    results.transactions.push(tx);
                    break;
                }
            }
        }

        // Process BUY actions (add to position)
        for (const pos of (actions.buy || [])) {
            for (const [portfolioId, state] of Object.entries(states)) {
                if (state.positions[pos.id]) {
                    const position = state.positions[pos.id];
                    // Record adjustment to mark as "bought more"
                    const tx = await txlog.recordAdjust(portfolioId, {
                        positionId: pos.id,
                        action: 'hold',
                        reason: 'Added to position'
                    });
                    results.bought++;
                    results.transactions.push(tx);
                    break;
                }
            }
        }

        // Process FLIP actions
        for (const pos of (actions.flip || [])) {
            for (const [portfolioId, state] of Object.entries(states)) {
                if (state.positions[pos.id]) {
                    const position = state.positions[pos.id];
                    const tx = await txlog.recordFlip(portfolioId, {
                        positionId: pos.id,
                        price: position.current,
                        reason: 'User flipped position'
                    });
                    results.flipped++;
                    results.transactions.push(tx);
                    break;
                }
            }
        }

        res.json({
            success: true,
            results,
            message: `Bought ${results.bought}, Sold ${results.sold}, Flipped ${results.flipped} position(s)`
        });
    } catch (error) {
        console.error('Error executing trades:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// POST /api/reset - Reset all portfolios to defaults
app.post('/api/reset', async (req, res) => {
    try {
        const fs = require('fs').promises;

        // Delete all JSONL files
        const files = await fs.readdir(txlog.PORTFOLIOS_DIR);
        for (const file of files) {
            if (file.endsWith('.jsonl')) {
                await fs.unlink(path.join(txlog.PORTFOLIOS_DIR, file));
            }
        }

        // Re-initialize all portfolios
        for (const id of Object.keys(DEFAULT_PORTFOLIOS)) {
            await initializePortfolio(id);
        }

        res.json({ success: true, message: 'All portfolios reset to defaults' });
    } catch (error) {
        console.error('Error resetting portfolios:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// GET /api/audit/:id - Audit portfolio chain integrity
app.get('/api/audit/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const chainResult = await txlog.verifyChain(id);
        const stats = await txlog.getLogStats(id);

        res.json({
            success: true,
            data: {
                chainIntegrity: chainResult,
                logStats: stats
            }
        });
    } catch (error) {
        console.error('Error auditing portfolio:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// GET /api/audit/:id/archive/:archive - Audit checkpoint against archive
app.get('/api/audit/:id/archive/:archive', async (req, res) => {
    try {
        const { id, archive } = req.params;
        const archivePath = path.join(txlog.ARCHIVE_DIR, archive);
        const auditResult = await txlog.auditCheckpoint(id, archivePath);

        res.json({ success: true, data: auditResult });
    } catch (error) {
        console.error('Error auditing archive:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

// Serve dashboard at root
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'dashboard.html'));
});

// Start server
app.listen(PORT, () => {
    console.log(`
╔═══════════════════════════════════════════════════════════════╗
║                    PRAESCIENTIA API                           ║
║              JSONL Blockchain Transaction Log                 ║
╠═══════════════════════════════════════════════════════════════╣
║  Server running at: http://localhost:${PORT}                     ║
║  Dashboard:         http://localhost:${PORT}/                    ║
║                                                               ║
║  API Endpoints:                                               ║
║    GET  /api/portfolios              - Get all portfolios     ║
║    GET  /api/portfolios/:id          - Get specific portfolio ║
║    GET  /api/portfolios/:id/logs     - Transaction log stats  ║
║    GET  /api/portfolios/:id/txs      - Raw transactions       ║
║    POST /api/trades                  - Execute trades         ║
║    POST /api/reset                   - Reset to defaults      ║
║    GET  /api/audit/:id               - Audit chain integrity  ║
║                                                               ║
║  Transaction Logs:                                            ║
║    portfolios/*.jsonl                - Active logs            ║
║    portfolios/archive/*_<ts>.jsonl   - Archived logs (>1MB)   ║
╚═══════════════════════════════════════════════════════════════╝
`);
});
