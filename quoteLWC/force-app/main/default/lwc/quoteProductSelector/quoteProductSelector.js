import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { FlowAttributeChangeEvent, FlowNavigationNextEvent } from 'lightning/flowSupport';
import getProducts from '@salesforce/apex/QuoteProductController.getProducts';
import getTierConfig from '@salesforce/apex/QuoteProductController.getTierConfig';
import createQuoteWithLineItems from '@salesforce/apex/QuoteProductController.createQuoteWithLineItems';
import getScheduleAdjustments from '@salesforce/apex/QuoteProductController.getScheduleAdjustments';
import getBaseStylePricing from '@salesforce/apex/QuoteProductController.getBaseStylePricing';
import getManufacturerAirRates from '@salesforce/apex/QuoteProductController.getManufacturerAirRates';
import getQuotePdfBase64 from '@salesforce/apex/QuoteProductController.getQuotePdfBase64';

const STEP_LOADING = 'loading';
const STEP_PRODUCT = 'product';
const STEP_ESTIMATOR = 'estimator';
const STEP_SUMMARY = 'summary';
const STEP_SUBMITTING = 'submitting';
const STEP_DONE = 'done';
const STEP_NO_PRODUCTS = 'no_products';

export default class QuoteProductSelector extends NavigationMixin(LightningElement) {
    // Flow input properties
    @api opportunityId;
    @api minQuantity;
    @api maxQuantity;
    @api priceScheduleName;
    @api expirationDate;

    // Flow output property
    @api quoteId;

    // Internal state
    currentStep = STEP_LOADING;
    products = [];
    currentProductIndex = 0;
    selectedProductsMap = {}; // keyed by product Id
    tierConfigData = [];
    tier72Adjustment = null;
    scheduleAdjustments = null; // Map<quantity, dollarAdjustment> from PriceAdjustmentSchedule
    baseStylePricingCache = {}; // keyed by product Id → { moqPrice, anchorQuantity, scheduleAdjustments }
    currentEstimateData = null; // result from quoteEstimator event
    errorMessage = '';
    showPricingForCurrent = false;
    currentPricingData = null;

    // Per-product header-field overrides (LDP, Base Margin, Manufacturer). Local to this
    // quote session only — never persisted back to Product2 / Account. Keyed by productId.
    // Shape: { [productId]: { ldp?, baseMargin? (percent, e.g. 35), manufacturer?: {manufacturerId, name, x144, x288, x576, x1008} } }
    productOverrides = {};

    get currentExistingPricing() {
        const productId = this.currentProduct?.Id;
        if (productId && this.selectedProductsMap[productId]) {
            const isQuick = this.selectedProductsMap[productId].isQuickProduct;
            return this.selectedProductsMap[productId].pricingRows.map(pr => ({
                ...pr,
                isBaseTier: this.filteredTiers.find(t => t.quantity === pr.quantity)?.isBaseTier || false,
                hasAir: isQuick ? false : [144, 288, 576, 1008].includes(pr.quantity),
                rowClass: this.filteredTiers.find(t => t.quantity === pr.quantity)?.isBaseTier
                    ? 'slds-hint-parent base-tier-row'
                    : 'slds-hint-parent'
            }));
        }
        return null;
    }

    get loadingMessage() {
        if (this.currentStep === STEP_LOADING) return 'Loading products...';
        if (this.currentStep === STEP_SUBMITTING) return 'Creating quote...';
        return '';
    }

    get isLoading() {
        return this.currentStep === STEP_LOADING || this.currentStep === STEP_SUBMITTING;
    }

    get isProductStep() {
        return this.currentStep === STEP_PRODUCT;
    }

    get isSummaryStep() {
        return this.currentStep === STEP_SUMMARY;
    }

    get isDone() {
        return this.currentStep === STEP_DONE;
    }

    get isNoProducts() {
        return this.currentStep === STEP_NO_PRODUCTS;
    }

    get isEstimatorStep() {
        return this.currentStep === STEP_ESTIMATOR;
    }

    get isQuickProduct() {
        const sp = this.currentProduct?.Special_Program_SAP__c;
        return sp && sp.toLowerCase().includes('quick');
    }

    get isSimpleProduct() {
        return this.currentProduct?.ProductClass === 'Simple';
    }

    get currentEstimatedBasePrice() {
        return this.currentEstimateData?.estimatedUnitPrice || null;
    }

    get currentBaseStylePricing() {
        const productId = this.currentProduct?.Id;
        return productId ? this.baseStylePricingCache[productId] : null;
    }

    get currentBaseStyleMoqPrice() {
        return this.currentBaseStylePricing?.moqPrice || null;
    }

    get currentBaseStyleAnchorQuantity() {
        return this.currentBaseStylePricing?.anchorQuantity || null;
    }

    get currentBaseStyleScheduleAdjustments() {
        return this.currentBaseStylePricing?.scheduleAdjustments || null;
    }

    get currentBaseStyleCode() {
        return this.currentProduct?.CDN_Style_ID_SAP__c || null;
    }

    get filteredTiers() {
        let a = Number(this.minQuantity) || 0;
        let b = Number(this.maxQuantity) || Infinity;
        const min = Math.min(a, b);
        const max = Math.max(a, b);
        return this.tierConfigData.filter(
            tier => tier.quantity >= min && tier.quantity <= max
        );
    }

    get currentProduct() {
        return this.products[this.currentProductIndex] || null;
    }

    get currentProductTitle() {
        const name = this.currentProduct?.Name || '';
        const code = this.currentProduct?.ProductCode;
        return code ? name + ' (' + code + ')' : name;
    }

    get currentOverride() {
        const productId = this.currentProduct?.Id;
        return (productId && this.productOverrides[productId]) || null;
    }

    get currentManufacturer() {
        const ov = this.currentOverride;
        if (ov?.manufacturer?.name) return ov.manufacturer.name;
        return this.currentProduct?.Manufacturer__r?.Name || 'N/A';
    }

    get currentManufacturerId() {
        const ov = this.currentOverride;
        if (ov?.manufacturer?.manufacturerId) return ov.manufacturer.manufacturerId;
        return this.currentProduct?.Manufacturer__c || null;
    }

    get currentManufacturerRates() {
        // Pass-through for the pricing card so air prices use overridden rates.
        return this.currentOverride?.manufacturer || null;
    }

    get currentBaseMargin() {
        // Decimal form (0.35 for 35%) for lightning-formatted-number percent display.
        return this.currentBaseMarginPercent / 100;
    }

    get currentBaseMarginPercent() {
        // Raw percent form (e.g. 35) — matches Account.Base_Margin_SAP__c storage.
        const ov = this.currentOverride;
        if (ov?.baseMargin != null) return ov.baseMargin;
        return this.currentProduct?.Account__r?.Base_Margin_SAP__c || 0;
    }

    get currentLdp() {
        const ov = this.currentOverride;
        if (ov?.ldp != null) return ov.ldp;
        return this.currentProduct?.LDP_SAP__c || 0;
    }

    get currentLeadTime() {
        return this.currentOverride?.leadTime ?? '21 days';
    }

    get showCustomDescription() {
        return this.currentOverride?.showCustomDescription || false;
    }

    get currentCustomDescription() {
        return this.currentOverride?.customDescription || '';
    }

    get currentOceanLeadTime() {
        return this.currentOverride?.oceanLeadTime ?? 'Ocean: 15 Weeks';
    }

    get currentAirLeadTime() {
        return this.currentOverride?.airLeadTime ?? 'Air: 7 Weeks';
    }

    get isCurrentEditable() {
        return !this.isQuickProduct;
    }

    get showCurrentLdp() {
        // LDP drives the base-tier cascade for all non-Quick products (Simple and
        // VariationParent). Quick products derive their anchor price from the estimator.
        return !this.isQuickProduct;
    }

    get showCurrentBaseMargin() {
        // Base margin drives the ocean-price cascade for all non-Quick products.
        // Quick products hide this field since their anchor price comes from the estimator.
        return !this.isQuickProduct;
    }

    get currentProductImageUrl() {
        return this.currentProduct?.Image_SAP__c || null;
    }

    // Null-safe template accessors. Some template bindings (e.g. {currentProduct.Name}
    // in the image alt attribute, {currentProduct.ProductClass} in the decision screen)
    // can throw "Cannot read properties of null" during step transitions or before
    // products finish loading, so route them through optional-chaining getters.
    get currentProductName() {
        return this.currentProduct?.Name || '';
    }

    get currentProductClass() {
        return this.currentProduct?.ProductClass || '';
    }

    get currentProductNumber() {
        return this.currentProductIndex + 1;
    }

    get totalProducts() {
        return this.products.length;
    }

    get selectedCount() {
        return Object.keys(this.selectedProductsMap).length;
    }

    get progressPercent() {
        if (this.totalProducts === 0) return 0;
        return Math.round((this.currentProductIndex / this.totalProducts) * 100);
    }

    get canGoBack() {
        return this.currentProductIndex > 0;
    }

    get summaryProducts() {
        return Object.values(this.selectedProductsMap).map(item => ({
            ...item,
            pricingRows: item.pricingRows.map(pr => ({
                ...pr,
                oceanMarginDecimal: pr.oceanMargin != null ? pr.oceanMargin / 100 : null,
                airMarginDecimal: pr.airMargin != null ? pr.airMargin / 100 : null
            }))
        }));
    }

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.currentStep = STEP_LOADING;
        this.errorMessage = '';

        try {
            const promises = [
                getProducts({ opportunityId: this.opportunityId }),
                getTierConfig()
            ];

            // Only fetch schedule adjustments if priceScheduleName is provided
            if (this.priceScheduleName) {
                promises.push(getScheduleAdjustments({ scheduleNameInput: this.priceScheduleName }));
            }

            const results = await Promise.all(promises);

            this.products = results[0] || [];
            this.tierConfigData = results[1] || [];
            if (results[2]) {
                this.scheduleAdjustments = results[2];
            }

            if (this.products.length === 0) {
                this.currentStep = STEP_NO_PRODUCTS;
            } else {
                this.currentProductIndex = 0;
                this.showPricingForCurrent = false;
                this.currentStep = STEP_PRODUCT;
            }
        } catch (error) {
            this.errorMessage = this.reduceErrors(error);
            this.currentStep = STEP_PRODUCT;
        }
    }

    // --- Override Handlers (Decision Screen: LDP / Base Margin / Manufacturer) ---

    _setOverride(partial) {
        const productId = this.currentProduct?.Id;
        if (!productId) return;
        const current = this.productOverrides[productId] || {};
        this.productOverrides = {
            ...this.productOverrides,
            [productId]: { ...current, ...partial }
        };
    }

    handleLeadTimeChange(event) {
        this._setOverride({ leadTime: event.target.value });
    }

    handleOceanLeadTimeChange(event) {
        this._setOverride({ oceanLeadTime: event.target.value });
    }

    handleAirLeadTimeChange(event) {
        this._setOverride({ airLeadTime: event.target.value });
    }

    handleToggleCustomDescription(event) {
        this._setOverride({ showCustomDescription: event.target.checked });
    }

    handleCustomDescriptionChange(event) {
        this._setOverride({ customDescription: event.target.value });
    }

    handleLdpChange(event) {
        const v = parseFloat(event.target.value);
        if (isNaN(v) || v <= 0) return;
        this._setOverride({ ldp: Math.round(v * 100) / 100 });
    }

    handleBaseMarginChange(event) {
        // Plain number input — user types the percent form directly (35 for 35%).
        // Stored as percent to match Account.Base_Margin_SAP__c storage.
        const raw = parseFloat(event.target.value);
        if (isNaN(raw)) return;
        this._setOverride({ baseMargin: Math.round(raw * 100) / 100 });
    }

    async handleManufacturerChange(event) {
        const newId = event.detail?.recordId || null;
        if (!newId) {
            this._setOverride({ manufacturer: null });
            return;
        }
        try {
            const rates = await getManufacturerAirRates({ manufacturerId: newId });
            this._setOverride({ manufacturer: rates || null });
        } catch (e) {
            this._setOverride({ manufacturer: null });
        }
    }

    // --- Product Step Handlers ---

    async handleQuoteYes() {
        if (this.isQuickProduct) {
            this.currentEstimateData = null;
            this.currentStep = STEP_ESTIMATOR;
            return;
        }

        // Non-Quick products (Simple and VariationParent) share the LDP/baseMargin
        // cascade and go straight to the pricing card.
        this.showPricingForCurrent = true;
    }

    async ensureBaseStylePricing() {
        const product = this.currentProduct;
        if (!product) return;
        const productId = product.Id;
        const cdnStyleId = product.CDN_Style_ID_SAP__c;
        if (!cdnStyleId || this.baseStylePricingCache[productId] !== undefined) {
            return;
        }
        try {
            const result = await getBaseStylePricing({ cdnStyleId });
            // Store result (even if null) so we don't re-query on navigation.
            this.baseStylePricingCache = {
                ...this.baseStylePricingCache,
                [productId]: result || null
            };
        } catch (error) {
            // Silent fallback to manual entry — don't block the UI.
            this.baseStylePricingCache = {
                ...this.baseStylePricingCache,
                [productId]: null
            };
        }
    }

    handleQuoteNo() {
        const productId = this.currentProduct?.Id;
        if (productId && this.selectedProductsMap[productId]) {
            const updated = { ...this.selectedProductsMap };
            delete updated[productId];
            this.selectedProductsMap = updated;
        }
        this.moveToNextProduct();
    }

    // --- Estimator Step Handlers ---

    async handleEstimateComplete(event) {
        this.currentEstimateData = event.detail;
        // Quick products also use the base-style pipeline for tier discounts.
        await this.ensureBaseStylePricing();
        // Move to product step with pricing card shown
        this.currentStep = STEP_PRODUCT;
        this.showPricingForCurrent = true;
    }

    handleCancelEstimator() {
        this.currentEstimateData = null;
        this.currentStep = STEP_PRODUCT;
        this.showPricingForCurrent = false;
    }

    handlePricingChange(event) {
        this.currentPricingData = event.detail;
    }

    handleConfirmPricing() {
        if (this.currentPricingData) {
            const entry = {
                productId: this.currentPricingData.productId,
                productName: this.currentProduct.Name,
                productCode: this.currentProduct.ProductCode,
                description: this.currentProduct.Description,
                ldp: this.currentProduct.LDP_SAP__c,
                tierPrices: this.currentPricingData.tierPrices,
                pricingRows: this.currentPricingData.pricingRows,
                isQuickProduct: this.isQuickProduct,
                leadTime: this.isQuickProduct ? this.currentLeadTime : '',
                oceanLeadTime: this.isQuickProduct ? '' : this.currentOceanLeadTime,
                airLeadTime: this.isQuickProduct ? '' : this.currentAirLeadTime,
                coo: this.currentOverride?.manufacturer?.coo || null,
                customDescription: this.currentCustomDescription || null,
                showMargin: !this.isQuickProduct
            };
            // Store estimator breakdown for quick products
            if (this.isQuickProduct && this.currentEstimateData) {
                entry.estimateBreakdown = this.currentEstimateData.breakdown;
                entry.estimatedUnitPrice = this.currentEstimateData.estimatedUnitPrice;
            }
            this.selectedProductsMap = {
                ...this.selectedProductsMap,
                [this.currentPricingData.productId]: entry
            };
        }
        this.currentEstimateData = null;
        this.moveToNextProduct();
    }

    handleCancelPricing() {
        this.showPricingForCurrent = false;
        this.currentPricingData = null;
    }

    handlePrevious() {
        if (this.currentProductIndex > 0) {
            this.currentProductIndex--;
            this.showPricingForCurrent = false;
            this.currentPricingData = null;
            this.currentEstimateData = null;

            const productId = this.currentProduct?.Id;
            if (productId && this.selectedProductsMap[productId]) {
                // Restore estimate data for quick products so pricing card can use it
                const entry = this.selectedProductsMap[productId];
                if (entry.isQuickProduct && entry.estimatedUnitPrice) {
                    this.currentEstimateData = {
                        estimatedUnitPrice: entry.estimatedUnitPrice,
                        breakdown: entry.estimateBreakdown
                    };
                }
                this.showPricingForCurrent = true;
            }
        }
    }

    handleSkipToSummary() {
        this.currentStep = STEP_SUMMARY;
    }

    moveToNextProduct() {
        this.showPricingForCurrent = false;
        this.currentPricingData = null;
        this.currentEstimateData = null;

        if (this.currentProductIndex < this.products.length - 1) {
            this.currentProductIndex++;

            const productId = this.currentProduct?.Id;
            if (productId && this.selectedProductsMap[productId]) {
                // Restore estimate data for quick products
                const entry = this.selectedProductsMap[productId];
                if (entry.isQuickProduct && entry.estimatedUnitPrice) {
                    this.currentEstimateData = {
                        estimatedUnitPrice: entry.estimatedUnitPrice,
                        breakdown: entry.estimateBreakdown
                    };
                }
                this.showPricingForCurrent = true;
            }
        } else {
            this.currentStep = STEP_SUMMARY;
        }
    }

    // --- Summary Step Handlers ---

    handleRemoveProduct(event) {
        const productId = event.detail.productId;
        const updated = { ...this.selectedProductsMap };
        delete updated[productId];
        this.selectedProductsMap = updated;
    }

    handleBackFromSummary() {
        this.currentProductIndex = this.products.length - 1;
        this.showPricingForCurrent = false;
        this.currentStep = STEP_PRODUCT;
    }

    async handleCreateQuote() {
        const selectedItems = Object.values(this.selectedProductsMap);
        if (selectedItems.length === 0) {
            this.errorMessage = 'No products selected. Please go back and select at least one product.';
            return;
        }

        this.currentStep = STEP_SUBMITTING;
        this.errorMessage = '';

        try {
            const quoteData = {
                opportunityId: this.opportunityId,
                minQuantity: Number(this.minQuantity) || null,
                maxQuantity: Number(this.maxQuantity) || null,
                expirationDate: this.expirationDate || null,
                lineItems: selectedItems.map(item => ({
                    productId: item.productId,
                    productName: item.productName,
                    productCode: item.productCode,
                    description: item.description,
                    ldp: item.ldp,
                    tierPrices: item.tierPrices,
                    isQuickProduct: item.isQuickProduct || false,
                    oceanLeadtime: item.isQuickProduct
                        ? (item.leadTime || null)
                        : (item.oceanLeadTime || 'Ocean: 15 Weeks'),
                    airLeadTime: item.isQuickProduct
                        ? null
                        : (item.airLeadTime || 'Air: 7 Weeks'),
                    coo: item.coo || null,
                    customDescription: item.customDescription || null
                }))
            };

            const result = await createQuoteWithLineItems({
                quoteDataJson: JSON.stringify(quoteData)
            });

            this.quoteId = result;
            this.dispatchEvent(new FlowAttributeChangeEvent('quoteId', this.quoteId));
            this.currentStep = STEP_DONE;

            // Trigger an immediate client-side download of the freshly-rendered Quote PDF.
            // Runs before navigation so the browser has initiated the download as the
            // user lands on the Quote record page. Failures here are non-fatal — the
            // @future attach path still saves the PDF to the Quote's Files.
            await this.downloadQuotePdf(this.quoteId);

            // Navigate to the created Quote record
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.quoteId,
                    objectApiName: 'Quote',
                    actionName: 'view'
                }
            });
        } catch (error) {
            this.errorMessage = this.reduceErrors(error);
            this.currentStep = STEP_SUMMARY;
        }
    }

    async downloadQuotePdf(quoteId) {
        try {
            const base64 = await getQuotePdfBase64({ quoteId });
            if (!base64) return;

            // Decode base64 to a Uint8Array so we can build a Blob. Doing this in
            // chunks avoids stack-overflow on very large PDFs when passing to
            // String.fromCharCode via apply.
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            const blob = new Blob([bytes], { type: 'application/pdf' });
            const url = URL.createObjectURL(blob);

            const a = document.createElement('a');
            a.href = url;
            a.download = 'Quote_' + quoteId + '.pdf';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            // Give the browser a moment to start the download before revoking.
            setTimeout(() => URL.revokeObjectURL(url), 1000);
        } catch (e) {
            // Non-fatal: the async @future attach still saves the PDF to the Quote record.
            // eslint-disable-next-line no-console
            console.error('Quote PDF download failed', e);
        }
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
