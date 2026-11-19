import { LightningElement, api } from 'lwc';
import getManufacturerAirRates from '@salesforce/apex/QuoteProductController.getManufacturerAirRates';

// Air pricing only available for tiers <= 1008
const AIR_TIERS = new Set([144, 288, 576, 1008]);

export default class ProductPricingCard extends LightningElement {
    @api product;
    @api tiers;
    @api tierConfig;
    @api tier72Adjustment;
    @api existingPricing;
    @api estimatedBasePrice;    // from estimator, used as anchor (tier 144) price for quick products
    @api scheduleAdjustments;   // Map<quantity, dollarAdjustment> from PriceAdjustmentSchedule
    @api isQuickProduct = false;
    @api baseStyleCode;         // Product2.CDN_Style_ID_SAP__c — shown to users on Quick cards instead of LDP
    @api baseStyleMoqPrice;     // from Authenticated PBE; anchor price for Simple products
    @api baseStyleAnchorQuantity; // from PurchaseQuantityRule.Minimum; tier row that gets MOQ price (Simple only)
    @api baseStyleScheduleAdjustments; // Map<quantity, dollarAdjustment> from PricebookEntryAdjustment → PriceAdjustmentSchedule

    // Header-field overrides forwarded from the parent decision screen. These are
    // local to this quote session (never persisted) and take precedence over the
    // product's default LDP / Account.Base_Margin / Manufacturer values.
    @api overrideLdp;                   // Number | undefined
    @api overrideBaseMargin;            // percent form (e.g. 35 for 35%) | undefined
    @api overrideManufacturerRates;     // { manufacturerId, name, x144, x288, x576, x1008 } | undefined

    // Cost-driven inputs (Quick Turn and North American Custom).
    @api tierCosts;          // { [quantity]: estimated LDP } from the cost service | null
    @api costPlus = false;   // true: sell price = tier LDP / (1 - base margin) (North American Custom)
    @api hideAir = false;    // true: never show or emit Air prices
    @api costMessage;        // why the cost service could not estimate LDP, if it could not
    @api costWarnings;       // caveats on an LDP that was estimated

    _pricingRows = [];
    _initialized = false;

    // User overrides from editable header fields (local to this quote; never persisted
    // back to Product2/Account). null means "use the value from the @api product record".
    _overrideLdp;
    _overrideBaseMargin;      // stored as percent number (e.g. 30 for 30%)
    _overrideManufacturer;    // { manufacturerId, name, x144, x288, x576, x1008 }

    get productTitle() {
        const name = this.product?.Name || '';
        const code = this.product?.ProductCode;
        return code ? name + ' (' + code + ')' : name;
    }

    get manufacturerName() {
        if (this._overrideManufacturer) return this._overrideManufacturer.name;
        if (this.overrideManufacturerRates?.name) return this.overrideManufacturerRates.name;
        return this.product?.Manufacturer__r?.Name || 'N/A';
    }

    get manufacturerId() {
        if (this._overrideManufacturer) return this._overrideManufacturer.manufacturerId;
        if (this.overrideManufacturerRates?.manufacturerId) {
            return this.overrideManufacturerRates.manufacturerId;
        }
        return this.product?.Manufacturer__c || null;
    }

    get baseMargin() {
        let raw;
        if (this._overrideBaseMargin != null) raw = this._overrideBaseMargin;
        else if (this.overrideBaseMargin != null) raw = this.overrideBaseMargin;
        else raw = this.product?.Account__r?.Base_Margin_SAP__c || 0;
        return raw / 100;
    }

    get ldp() {
        if (this._overrideLdp != null) return this._overrideLdp;
        if (this.overrideLdp != null) return this.overrideLdp;
        return this.product?.LDP_SAP__c || 0;
    }

    get hasTierCosts() {
        return !!this.tierCosts && Object.keys(this.tierCosts).length > 0;
    }

    // Quick Turn and cost-plus cards track an LDP per tier that the user can edit.
    get usesTierLdp() {
        return this.isQuickProduct || (this.costPlus && this.hasTierCosts);
    }

    getLdpForQuantity(qty) {
        if (this.usesTierLdp) {
            // A row's own LDP (calculated, or edited by the user) wins once rows exist.
            const row = this._pricingRows.find(r => r.quantity === qty);
            if (row && row.ldp != null) return row.ldp;
            const calculated = this.tierCosts ? Number(this.tierCosts[qty]) : NaN;
            if (calculated > 0) return calculated;
            // Cost-plus without a calculated cost falls back to the header LDP below.
            // Quick Turn has no header LDP, so its margin stays blank until one is entered.
            if (this.isQuickProduct) return 0;
        }
        const tierField = { 144: 'LDP_144_SAP__c', 288: 'LDP_288_SAP__c', 432: 'LDP_432_SAP__c' };
        const field = tierField[qty];
        if (field && this.product?.[field]) return this.product[field];
        return this.ldp;
    }

    get baseMarginPercent() {
        // Percent form (e.g. 35 for 35%) for the plain-number editable input.
        if (this._overrideBaseMargin != null) return this._overrideBaseMargin;
        if (this.overrideBaseMargin != null) return this.overrideBaseMargin;
        return this.product?.Account__r?.Base_Margin_SAP__c || 0;
    }

    get isEditable() {
        return !this.isQuickProduct;
    }

    get productImageUrl() {
        return this.product?.Image_SAP__c || null;
    }

    get isSimpleProduct() {
        return this.product?.ProductClass === 'Simple';
    }

    get isVariationParent() {
        return this.product?.ProductClass === 'VariationParent';
    }

    get pricingRows() {
        return this._pricingRows;
    }

    get hasAirTiers() {
        return this._pricingRows.some(row => row.hasAir);
    }

    get priceColumnLabel() {
        return this.hasAirTiers ? 'Ocean Price' : 'Price';
    }

    get marginColumnLabel() {
        return this.hasAirTiers ? 'Ocean Margin' : 'Margin';
    }

    get showMarginColumn() {
        // LDP and margin are visible to every rep on every product type.
        return true;
    }

    get showLdpColumn() {
        return this.usesTierLdp;
    }

    get showLdp() {
        // The single header LDP is replaced by the per-tier LDP column on cost-driven cards.
        return !this.usesTierLdp;
    }

    get showCostNotice() {
        return this.usesTierLdp && !this.hasTierCosts;
    }

    get showCostWarnings() {
        return this.usesTierLdp && this.hasTierCosts && !!this.costWarnings;
    }

    get costNoticeText() {
        const reason = this.costMessage ? this.costMessage + ' ' : 'No estimated LDP is available for this product. ';
        return reason + 'Enter an LDP per tier to see margin.';
    }

    get showBaseMargin() {
        // Base margin drives pricing for all non-Quick products (Simple and
        // VariationParent use the same LDP/margin cascade). Quick products
        // derive their anchor price from the estimator.
        return !this.isQuickProduct;
    }

    get showSimpleManualNotice() {
        return !this.isQuickProduct && !this.usesTierLdp && !(this.ldp > 0 && this.baseMargin > 0);
    }

    marginFor(ldp, price) {
        return ldp > 0 && price > 0 ? this.round2((1 - (ldp / price)) * 100) : null;
    }

    renderedCallback() {
        if (!this._initialized && this.tiers?.length > 0 && this.product) {
            this._initialized = true;
            this.initializePricing();
        }
    }

    getAirFreightRate(quantity) {
        // Precedence: card-local override (if user edits the card directly) →
        // parent decision-screen override (via @api) → product's original manufacturer.
        const internal = this._overrideManufacturer;
        if (internal) {
            const map = { 144: internal.x144, 288: internal.x288, 576: internal.x576, 1008: internal.x1008 };
            return map[quantity] || 0;
        }
        const fromParent = this.overrideManufacturerRates;
        if (fromParent) {
            const map = { 144: fromParent.x144, 288: fromParent.x288, 576: fromParent.x576, 1008: fromParent.x1008 };
            return map[quantity] || 0;
        }
        const mfr = this.product?.Manufacturer__r;
        if (!mfr) return 0;
        const rateMap = {
            144: mfr.X144_Air_Rate__c || 0,
            288: mfr.X288_Air_Rate__c || 0,
            576: mfr.X576_Air_Rate__c || 0,
            1008: mfr.X1008_Air_Rate__c || 0
        };
        return rateMap[quantity] || 0;
    }

    handleLdpChange(event) {
        const v = parseFloat(event.target.value);
        if (isNaN(v) || v <= 0) return;
        this._overrideLdp = this.round2(v);
        this.reSeedFromInputs();
    }

    handleBaseMarginChange(event) {
        // Plain number input — user types the percent form directly (35 for 35%).
        const raw = parseFloat(event.target.value);
        if (isNaN(raw)) return;
        this._overrideBaseMargin = this.round2(raw);
        this.reSeedFromInputs();
    }

    async handleManufacturerChange(event) {
        const newId = event.detail?.recordId || null;
        if (!newId) {
            this._overrideManufacturer = null;
        } else {
            try {
                const rates = await getManufacturerAirRates({ manufacturerId: newId });
                this._overrideManufacturer = rates || null;
            } catch (e) {
                this._overrideManufacturer = null;
            }
        }
        this.reDeriveAirOnly();
    }

    reSeedFromInputs() {
        // Re-run initialization so base-tier Ocean price, cascade, and every margin
        // reflect the new LDP / Base Margin. Any prior user cell edits on this card
        // are discarded — this matches the "edit inputs = regenerate" mental model.
        this._initialized = false;
        this.initializePricing();
        this._initialized = true;
    }

    reDeriveAirOnly() {
        // Ocean prices untouched; re-derive airPrice + airMargin for every hasAir row.
        this._pricingRows = this._pricingRows.map(row => {
            if (!row.hasAir || row.oceanPrice == null) return row;
            const airRate = this.getAirFreightRate(row.quantity);
            const airPrice = this.roundNickel(row.oceanPrice + airRate);
            const tierLdp = this.getLdpForQuantity(row.quantity);
            const airMargin = tierLdp > 0
                ? this.round2((1 - (tierLdp / airPrice)) * 100)
                : null;
            return { ...row, airPrice, airMargin };
        });
        this.dispatchPricingChange();
    }

    initializePricing() {
        if (this.existingPricing && this.existingPricing.length > 0) {
            this._pricingRows = this.existingPricing.map(row => ({ ...row }));
            return;
        }

        // Per-tier fallback: prefer base-style PricebookEntryAdjustment schedule for this quantity,
        // fall back to the Flow's priceScheduleName map, default to 0. Merging per-tier (not per-map)
        // avoids the regression where a populated base-style map missing some quantities collapses
        // every non-anchor tier to the anchor price.
        const lookupAdj = (qty) => {
            const baseMap = this.baseStyleScheduleAdjustments || {};
            const schedMap = this.scheduleAdjustments || {};
            if (baseMap[qty] != null) return baseMap[qty];
            if (schedMap[qty] != null) return schedMap[qty];
            return 0;
        };

        // Quick product mode: single price column; anchor at the MOQ derived from
        // PurchaseQuantityRule.Minimum (same source used for Simple products) so the
        // decorated estimator price lands on the MOQ tier. Falls back to 144 when the
        // base-style pipeline didn't return an anchor quantity.
        if (this.isQuickProduct && this.estimatedBasePrice > 0) {
            const anchorQty = this.baseStyleAnchorQuantity != null
                ? Number(this.baseStyleAnchorQuantity)
                : 144;

            this._pricingRows = this.tiers.map(tier => {
                const qty = tier.quantity;
                const price = qty === anchorQty
                    ? this.roundNickel(this.estimatedBasePrice)
                    : this.roundNickel(this.estimatedBasePrice - lookupAdj(qty));
                const tierLdp = this.getLdpForQuantity(qty);
                const margin = this.marginFor(tierLdp, price);

                return {
                    quantity: qty,
                    ldp: tierLdp > 0 ? this.round4(tierLdp) : null,
                    // Quick products don't have a meaningful "base tier" row — 1008 is not visually special
                    // and 144 is only a mathematical anchor. Suppress the badge and highlight for every row.
                    isBaseTier: false,
                    hasAir: false,
                    oceanPrice: price,
                    oceanMargin: margin,
                    airPrice: null,
                    airMargin: null,
                    rowClass: 'slds-hint-parent'
                };
            });

            this.dispatchPricingChange();
            return;
        }

        // Cost-plus mode (North American Custom): every tier is priced from its own
        // estimated LDP at the account base margin. No base tier, no Air.
        if (!this.isQuickProduct && this.costPlus && this.hasTierCosts) {
            const margin = this.baseMargin;
            this._pricingRows = this.tiers.map(tier => {
                const qty = tier.quantity;
                const tierLdp = this.getLdpForQuantity(qty);
                const price = tierLdp > 0 && margin > 0 && margin < 1
                    ? this.roundNickel(tierLdp / (1 - margin))
                    : null;
                return {
                    quantity: qty,
                    ldp: tierLdp > 0 ? this.round4(tierLdp) : null,
                    isBaseTier: false,
                    hasAir: false,
                    oceanPrice: price,
                    oceanMargin: this.marginFor(tierLdp, price),
                    airPrice: null,
                    airMargin: null,
                    rowClass: 'slds-hint-parent'
                };
            });

            this.dispatchPricingChange();
            return;
        }

        const tierAdjMap = {};
        if (this.tierConfig) {
            this.tierConfig.forEach(tc => {
                tierAdjMap[tc.quantity] = tc;
            });
        }

        // Non-Quick products (Simple and VariationParent) share the LDP/baseMargin
        // cascade: base-tier ocean price = LDP / (1 - baseMargin), other tiers derive
        // via Tier_Adjustment__mdt (Dollar or Percent).
        let baseOceanPrice = 0;
        if (!this.isQuickProduct && this.ldp > 0 && this.baseMargin > 0) {
            baseOceanPrice = this.ldp / (1 - this.baseMargin);
        }

        this._pricingRows = this.tiers.map(tier => {
            const qty = tier.quantity;
            const isBase = tier.isBaseTier;
            const adj = tierAdjMap[qty];
            const hasAir = !this.hideAir && AIR_TIERS.has(qty);
            let oceanPrice = null;
            let oceanMargin = null;
            let airPrice = null;
            let airMargin = null;

            if (!this.isQuickProduct && baseOceanPrice > 0) {
                if (isBase) {
                    oceanPrice = baseOceanPrice;
                } else if (adj) {
                    if (adj.adjustmentType === 'Dollar' && adj.dollarAdjustment != null) {
                        oceanPrice = baseOceanPrice + adj.dollarAdjustment;
                    } else if (adj.adjustmentType === 'Percent' && adj.percentDiscount != null) {
                        oceanPrice = baseOceanPrice * (1 - adj.percentDiscount / 100);
                    }
                }

                const tierLdp = this.getLdpForQuantity(qty);
                if (oceanPrice != null && tierLdp > 0) {
                    oceanMargin = (1 - (tierLdp / oceanPrice)) * 100;
                }

                // Air price = Ocean price + air freight rate from manufacturer
                if (hasAir && oceanPrice != null) {
                    const airRate = this.getAirFreightRate(qty);
                    airPrice = oceanPrice + airRate;
                    if (tierLdp > 0) {
                        airMargin = (1 - (tierLdp / airPrice)) * 100;
                    }
                }
            }

            return {
                quantity: qty,
                isBaseTier: isBase,
                hasAir: hasAir,
                oceanPrice: oceanPrice != null ? this.roundNickel(oceanPrice) : null,
                oceanMargin: oceanMargin != null ? this.round2(oceanMargin) : null,
                airPrice: airPrice != null ? this.roundNickel(airPrice) : null,
                airMargin: airMargin != null ? this.round2(airMargin) : null,
                rowClass: isBase ? 'slds-hint-parent base-tier-row' : 'slds-hint-parent'
            };
        });

        this.dispatchPricingChange();
    }

    handlePriceChange(event) {
        const quantity = parseFloat(event.target.dataset.quantity);
        const field = event.target.dataset.field; // 'oceanPrice' or 'airPrice'
        const newPrice = parseFloat(event.target.value);

        if (isNaN(newPrice) || newPrice <= 0) return;

        const rowIndex = this._pricingRows.findIndex(r => r.quantity === quantity);
        if (rowIndex === -1) return;

        const row = this._pricingRows[rowIndex];
        const isBase = row.isBaseTier;
        const marginField = field === 'oceanPrice' ? 'oceanMargin' : 'airMargin';

        const tierLdp = this.getLdpForQuantity(quantity);
        const newMargin = tierLdp > 0 ? this.round2((1 - (tierLdp / newPrice)) * 100) : null;

        this._pricingRows[rowIndex] = {
            ...row,
            [field]: this.roundNickel(newPrice),
            [marginField]: newMargin
        };

        // If base tier Ocean price was edited, recalculate all other Ocean tiers
        if (isBase && field === 'oceanPrice') {
            this.recalculateFromBase(newPrice);
        }

        this._pricingRows = [...this._pricingRows];
        this.dispatchPricingChange();
    }

    handleTierLdpChange(event) {
        const quantity = parseFloat(event.target.dataset.quantity);
        const newLdp = parseFloat(event.target.value);
        if (isNaN(newLdp) || newLdp <= 0) return;

        const rowIndex = this._pricingRows.findIndex(r => r.quantity === quantity);
        if (rowIndex === -1) return;

        const row = this._pricingRows[rowIndex];
        const ldp = this.round4(newLdp);
        let price = row.oceanPrice;
        // Cost-plus re-prices the tier at the base margin; list-driven Quick Turn keeps
        // its price and only the margin moves.
        if (this.costPlus && !this.isQuickProduct) {
            const margin = this.baseMargin;
            if (margin > 0 && margin < 1) price = this.roundNickel(ldp / (1 - margin));
        }

        this._pricingRows[rowIndex] = {
            ...row,
            ldp,
            oceanPrice: price,
            oceanMargin: this.marginFor(ldp, price)
        };
        this._pricingRows = [...this._pricingRows];
        this.dispatchPricingChange();
    }

    handleMarginChange(event) {
        const quantity = parseFloat(event.target.dataset.quantity);
        const field = event.target.dataset.field; // 'oceanMargin' or 'airMargin'
        const newMargin = parseFloat(event.target.value);

        if (isNaN(newMargin) || newMargin >= 100) return;

        const rowIndex = this._pricingRows.findIndex(r => r.quantity === quantity);
        if (rowIndex === -1) return;

        const row = this._pricingRows[rowIndex];
        const isBase = row.isBaseTier;
        const priceField = field === 'oceanMargin' ? 'oceanPrice' : 'airPrice';

        const tierLdp = this.getLdpForQuantity(quantity);
        const newPrice = tierLdp > 0 ? this.roundNickel(tierLdp / (1 - newMargin / 100)) : null;

        this._pricingRows[rowIndex] = {
            ...row,
            [field]: this.round2(newMargin),
            [priceField]: newPrice
        };

        // If base tier Ocean margin was edited, recalculate all other Ocean tiers
        if (isBase && field === 'oceanMargin' && newPrice != null) {
            this.recalculateFromBase(newPrice);
        }

        this._pricingRows = [...this._pricingRows];
        this.dispatchPricingChange();
    }

    recalculateFromBase(newBaseOceanPrice) {
        const tierAdjMap = {};
        if (this.tierConfig) {
            this.tierConfig.forEach(tc => {
                tierAdjMap[tc.quantity] = tc;
            });
        }

        this._pricingRows = this._pricingRows.map(row => {
            const tierLdp = this.getLdpForQuantity(row.quantity);
            if (row.isBaseTier) {
                // Recalculate base tier air price with new ocean price
                if (row.hasAir) {
                    const airRate = this.getAirFreightRate(row.quantity);
                    const airPrice = newBaseOceanPrice + airRate;
                    const airMargin = tierLdp > 0 ? (1 - (tierLdp / airPrice)) * 100 : null;
                    return {
                        ...row,
                        airPrice: this.roundNickel(airPrice),
                        airMargin: airMargin != null ? this.round2(airMargin) : null
                    };
                }
                return row;
            }

            const adj = tierAdjMap[row.quantity];
            let oceanPrice = null;

            if (adj) {
                if (adj.adjustmentType === 'Dollar' && adj.dollarAdjustment != null) {
                    oceanPrice = newBaseOceanPrice + adj.dollarAdjustment;
                } else if (adj.adjustmentType === 'Percent' && adj.percentDiscount != null) {
                    oceanPrice = newBaseOceanPrice * (1 - adj.percentDiscount / 100);
                }
            }

            const oceanMargin = (oceanPrice != null && tierLdp > 0)
                ? (1 - (tierLdp / oceanPrice)) * 100
                : null;

            // Recalculate air price = ocean price + air freight rate
            let airPrice = row.airPrice;
            let airMargin = row.airMargin;
            if (row.hasAir && oceanPrice != null) {
                const airRate = this.getAirFreightRate(row.quantity);
                airPrice = this.roundNickel(oceanPrice + airRate);
                airMargin = tierLdp > 0 ? this.round2((1 - (tierLdp / airPrice)) * 100) : null;
            }

            return {
                ...row,
                oceanPrice: oceanPrice != null ? this.roundNickel(oceanPrice) : row.oceanPrice,
                oceanMargin: oceanMargin != null ? this.round2(oceanMargin) : row.oceanMargin,
                airPrice: airPrice,
                airMargin: airMargin
            };
        });
    }

    dispatchPricingChange() {
        const tierPrices = {};
        this._pricingRows.forEach(row => {
            if (row.oceanPrice != null) {
                tierPrices[row.quantity + '_Ocean'] = row.oceanPrice;
            }
            if (row.airPrice != null && !this.hideAir) {
                tierPrices[row.quantity + '_Air'] = row.airPrice;
            }
        });

        this.dispatchEvent(new CustomEvent('pricingchange', {
            detail: {
                productId: this.product.Id,
                pricingRows: this._pricingRows.map(row => ({
                    quantity: row.quantity,
                    ldp: row.ldp != null ? row.ldp : null,
                    oceanPrice: row.oceanPrice,
                    oceanMargin: row.oceanMargin,
                    airPrice: row.airPrice,
                    airMargin: row.airMargin
                })),
                tierPrices: tierPrices
            }
        }));
    }

    @api
    getPricingData() {
        const tierPrices = {};
        this._pricingRows.forEach(row => {
            if (row.oceanPrice != null) {
                tierPrices[row.quantity + '_Ocean'] = row.oceanPrice;
            }
            if (row.airPrice != null && !this.hideAir) {
                tierPrices[row.quantity + '_Air'] = row.airPrice;
            }
        });

        return {
            productId: this.product.Id,
            productName: this.product.Name,
            productCode: this.product.ProductCode,
            description: this.product.Description,
            ldp: this.ldp,
            tierPrices: tierPrices,
            pricingRows: this._pricingRows.map(row => ({
                quantity: row.quantity,
                ldp: row.ldp != null ? row.ldp : null,
                oceanPrice: row.oceanPrice,
                oceanMargin: row.oceanMargin,
                airPrice: row.airPrice,
                airMargin: row.airMargin
            }))
        };
    }

    roundNickel(val) {
        return Math.ceil(val * 20) / 20;
    }

    round4(val) {
        return Math.round(val * 10000) / 10000;
    }

    round2(val) {
        return Math.round(val * 100) / 100;
    }
}
