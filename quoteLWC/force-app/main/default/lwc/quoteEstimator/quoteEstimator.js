import { LightningElement, api, track } from 'lwc';
import getEstimatorProduct from '@salesforce/apex/QuoteProductController.getEstimatorProduct';
import getDecorationOptions from '@salesforce/apex/QuoteProductController.getDecorationOptions';
import getEstimatedPrice from '@salesforce/apex/QuoteProductController.getEstimatedPrice';
import getQuickTurnCosts from '@salesforce/apex/QuoteProductController.getQuickTurnCosts';

// Estimator__c picklist values for decoration usage filtering
const USAGE_ANY = 'Decoration';
const USAGE_MAIN = 'Decoration_Main';
const USAGE_ADDL = 'Decoration_Additional';

export default class QuoteEstimator extends LightningElement {
    @api product;       // Opportunity Product2 record with CDN_Style_ID_SAP__c, LDP_SAP__c, etc.

    // Quantity the estimate is shown at: the smallest tier selected for this quote.
    @api minQuantity;
    // Tier the list price applies to (PurchaseQuantityRule minimum on the base style).
    @api anchorQuantity;
    // { [quantity]: dollars off the list price } for the base style.
    @api scheduleAdjustments;
    // Manufacturer whose charges and upcharges drive the LDP estimate.
    @api manufacturerId;
    // Quantity tiers on this quote; LDP is estimated for each.
    @api quantities;
    // true for North American Custom: no list price, sell price is cost-plus.
    @api costOnly = false;
    // Account base margin in percent form (35 for 35%); used in cost-only mode.
    @api baseMarginPercent;

    // Internal state
    estimatorProduct = null;    // matched Product2 where ProductCode = CDN_Style_ID_SAP__c
    decorationProducts = [];    // all decoration Product2 records
    selectedMainDecoration = null;
    @track selectedAdditionalDecorations = [];
    estimateResult = null;      // { totalPrice, items[] }
    costResult = null;          // QuoteCostService.CostResult
    _requestSeq = 0;            // discards responses from superseded requests
    isLoading = false;
    errorMessage = '';
    _initialized = false;

    // --- Computed Properties ---

    get productName() {
        return this.product?.Name || '';
    }

    get productCode() {
        return this.product?.ProductCode || '';
    }

    get productImageUrl() {
        return this.product?.Image_SAP__c || null;
    }

    get ldp() {
        return this.product?.LDP_SAP__c || 0;
    }

    get cdnStyleId() {
        return this.product?.CDN_Style_ID_SAP__c || '';
    }

    get hasEstimatorProduct() {
        return this.estimatorProduct != null;
    }

    get estimatorProductName() {
        return this.estimatorProduct?.Name || '';
    }

    get mainDecorationOptions() {
        return this.decorationProducts
            .filter(p => p.Estimator__c === USAGE_ANY || p.Estimator__c === USAGE_MAIN)
            .map(p => ({ label: p.Name, value: p.Id }));
    }

    get additionalDecorationOptions() {
        return this.decorationProducts
            .filter(p => p.Estimator__c === USAGE_ANY || p.Estimator__c === USAGE_ADDL)
            .map(p => ({ label: p.Name, value: p.Id }));
    }

    get hasAdditionalDecorationOptions() {
        return this.additionalDecorationOptions.length > 0;
    }

    get hasSelectedAdditionalDecorations() {
        return this.selectedAdditionalDecorations.length > 0;
    }

    get hasEstimate() {
        return this.estimateResult != null;
    }

    get estimateItems() {
        if (!this.estimateResult) return [];
        return this.estimateResult.items.map((item, idx) => ({
            ...item,
            key: 'item-' + idx
        }));
    }

    get estimateTotalPrice() {
        return this.estimateResult?.totalPrice || 0;
    }

    get isConfirmDisabled() {
        if (this.isLoading) return true;
        if (this.costOnly) return !this.selectedMainDecoration;
        return !this.hasEstimate;
    }

    get showPriceBreakdown() {
        return this.hasEstimate && !this.costOnly;
    }

    get showNoEstimatorActions() {
        return !this.isLoading && !this.hasEstimatorProduct;
    }

    get canContinueWithoutEstimator() {
        // Cost-only products can still be quoted from a manually entered LDP.
        return this.costOnly && !this.isLoading && !this.hasEstimatorProduct;
    }

    // --- Selected-quantity price ---

    get effectiveAnchorQuantity() {
        // Mirrors productPricingCard: the list price sits on the anchor tier, 144 by default.
        return this.anchorQuantity != null ? Number(this.anchorQuantity) : 144;
    }

    get displayQuantity() {
        const min = Number(this.minQuantity);
        return min > 0 ? min : this.effectiveAnchorQuantity;
    }

    get quantityAdjustment() {
        if (this.displayQuantity === this.effectiveAnchorQuantity) return 0;
        const adj = this.scheduleAdjustments ? Number(this.scheduleAdjustments[this.displayQuantity]) : NaN;
        return isNaN(adj) ? 0 : adj;
    }

    get hasQuantityAdjustment() {
        return this.quantityAdjustment !== 0;
    }

    get quantityAdjustmentDisplay() {
        return -this.quantityAdjustment;
    }

    get quantityAdjustmentLabel() {
        return 'Adjustment from ' + this.effectiveAnchorQuantity + ' to ' + this.displayQuantity + ' pcs';
    }

    get priceAtQuantityLabel() {
        return 'Estimated Unit Price at ' + this.displayQuantity + ' pcs';
    }

    // Price at the selected minimum quantity, using the same rule as the pricing card.
    get priceAtQuantity() {
        if (!this.estimateResult) return null;
        return this.roundNickel(this.estimateResult.totalPrice - this.quantityAdjustment);
    }

    // --- Cost ---

    get hasCost() {
        return !!this.costResult?.available;
    }

    get costMessage() {
        return this.costResult && !this.costResult.available ? this.costResult.message : '';
    }

    get costWarnings() {
        return (this.costResult?.warnings || []).map((text, idx) => ({ key: 'warn-' + idx, text }));
    }

    get costLines() {
        return (this.costResult?.lines || []).map((line, idx) => ({ ...line, key: 'cost-' + idx }));
    }

    get costTier() {
        if (!this.hasCost) return null;
        return this.costResult.tiers.find(t => t.quantity === this.displayQuantity) || null;
    }

    get costHeading() {
        return 'Estimated Cost at ' + this.displayQuantity + ' pcs (internal)';
    }

    get baseFob() {
        return this.costResult?.baseFob;
    }

    get hasUpcharge() {
        return !!this.costTier?.upchargeType;
    }

    get upchargeLabel() {
        const tier = this.costTier;
        if (!tier?.upchargeType) return '';
        return tier.upchargeType === 'Multiplier'
            ? 'Small-quantity upcharge (' + tier.upchargeValue + 'x FOB)'
            : 'Small-quantity upcharge (per piece)';
    }

    get upchargeAmount() {
        const tier = this.costTier;
        return tier ? tier.fob - this.costResult.baseFob : null;
    }

    get landedCharges() {
        const tier = this.costTier;
        return tier ? tier.ldp - tier.fob : null;
    }

    get ldpAtQuantity() {
        return this.costTier?.ldp ?? null;
    }

    // Sell price the margin is measured against: list-driven price, or cost-plus.
    get sellPriceAtQuantity() {
        if (!this.costOnly) return this.priceAtQuantity;
        const ldp = this.ldpAtQuantity;
        const margin = Number(this.baseMarginPercent) / 100;
        if (!(ldp > 0) || !(margin > 0) || margin >= 1) return null;
        return this.roundNickel(ldp / (1 - margin));
    }

    get showCostPlusPrice() {
        return this.costOnly && this.sellPriceAtQuantity != null;
    }

    get marginAtQuantity() {
        const ldp = this.ldpAtQuantity;
        const price = this.sellPriceAtQuantity;
        return ldp > 0 && price > 0 ? 1 - ldp / price : null;
    }

    get hasMargin() {
        return this.marginAtQuantity != null;
    }

    // --- Lifecycle ---

    connectedCallback() {
        if (!this._initialized) {
            this._initialized = true;
            this.loadEstimatorData();
        }
    }

    // --- Data Loading ---

    async loadEstimatorData() {
        this.isLoading = true;
        this.errorMessage = '';

        try {
            // Find the estimator product matching this opportunity product's CDN style
            const estProduct = await getEstimatorProduct({ cdnStyleId: this.cdnStyleId });
            if (!estProduct) {
                this.errorMessage = 'No estimator product found matching style ID: ' + this.cdnStyleId;
                this.isLoading = false;
                return;
            }
            this.estimatorProduct = estProduct;

            // Load decoration options
            const decorations = await getDecorationOptions({ estimatorProductId: estProduct.Id });
            this.decorationProducts = decorations || [];

            if (this.decorationProducts.length === 0) {
                this.errorMessage = 'No decoration options found for this product.';
            }
        } catch (error) {
            this.errorMessage = this.reduceErrors(error);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Event Handlers ---

    handleMainDecorationChange(event) {
        this.selectedMainDecoration = event.detail.value;
        this.estimateResult = null;
        this.costResult = null;
        this.loadEstimate();
    }

    handleAdditionalDecorationChange(event) {
        const selectedId = event.detail.value;
        const product = this.decorationProducts.find(p => p.Id === selectedId);
        if (product) {
            this.selectedAdditionalDecorations = [
                ...this.selectedAdditionalDecorations,
                { id: product.Id, name: product.Name, key: Date.now() + '-' + Math.random() }
            ];
            this.loadEstimate();
        }
        // Reset the combobox
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const combo = this.template.querySelector('[data-id="addl-decoration-combo"]');
            if (combo) combo.value = null;
        }, 0);
    }

    handleRemoveDecoration(event) {
        const removeKey = event.currentTarget.dataset.key;
        this.selectedAdditionalDecorations = this.selectedAdditionalDecorations.filter(
            d => d.key !== removeKey
        );
        this.loadEstimate();
    }

    async loadEstimate() {
        if (!this.selectedMainDecoration || !this.estimatorProduct) {
            this.estimateResult = null;
            this.costResult = null;
            return;
        }

        const seq = ++this._requestSeq;
        this.isLoading = true;
        this.errorMessage = '';

        const additionalIds = this.selectedAdditionalDecorations.map(d => d.id);

        // Price and cost are independent: a missing cost never blocks the price.
        const pricePromise = this.costOnly
            ? Promise.resolve(null)
            : getEstimatedPrice({
                estimatorProductId: this.estimatorProduct.Id,
                mainDecorationId: this.selectedMainDecoration,
                additionalDecorationIds: additionalIds
            });
        const costPromise = getQuickTurnCosts({
            estimatorProductId: this.estimatorProduct.Id,
            mainDecorationId: this.selectedMainDecoration,
            additionalDecorationIds: additionalIds,
            manufacturerId: this.manufacturerId || null,
            quantities: this.costQuantities
        }).catch(() => ({
            available: false,
            message: 'LDP could not be estimated.',
            warnings: [],
            lines: [],
            tiers: []
        }));

        try {
            const [price, cost] = await Promise.all([pricePromise, costPromise]);
            if (seq !== this._requestSeq) return;
            this.estimateResult = price;
            this.costResult = cost;
        } catch (error) {
            if (seq !== this._requestSeq) return;
            this.errorMessage = this.reduceErrors(error);
            this.estimateResult = null;
            this.costResult = null;
        } finally {
            if (seq === this._requestSeq) this.isLoading = false;
        }
    }

    get costQuantities() {
        const set = new Set((this.quantities || []).map(Number).filter(q => q > 0));
        set.add(this.displayQuantity);
        return [...set];
    }

    handleConfirmEstimate() {
        if (this.isConfirmDisabled) return;

        this.dispatchEvent(new CustomEvent('estimatecomplete', {
            detail: {
                // List price on the anchor tier; the pricing card derives every tier from it.
                estimatedUnitPrice: this.estimateResult ? this.estimateResult.totalPrice : null,
                estimatorProductId: this.estimatorProduct.Id,
                mainDecorationId: this.selectedMainDecoration,
                additionalDecorationIds: this.selectedAdditionalDecorations.map(d => d.id),
                breakdown: this.estimateResult
                    ? this.estimateResult.items.map(item => ({ label: item.label, price: item.price }))
                    : [],
                costs: this.costResult
            }
        }));
    }

    handleContinueWithoutEstimator() {
        this.dispatchEvent(new CustomEvent('estimatecomplete', {
            detail: { estimatedUnitPrice: null, breakdown: [], costs: null }
        }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    // --- Utilities ---

    roundNickel(val) {
        return Math.ceil(val * 20) / 20;
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        if (Array.isArray(error?.body)) {
            return error.body.map(e => e.message).join(', ');
        }
        return 'An unknown error occurred.';
    }
}
