import { LightningElement, api, track } from 'lwc';
import getEstimatorProduct from '@salesforce/apex/QuoteProductController.getEstimatorProduct';
import getDecorationOptions from '@salesforce/apex/QuoteProductController.getDecorationOptions';
import getEstimatedPrice from '@salesforce/apex/QuoteProductController.getEstimatedPrice';

// Estimator__c picklist values for decoration usage filtering
const USAGE_ANY = 'Decoration';
const USAGE_MAIN = 'Decoration_Main';
const USAGE_ADDL = 'Decoration_Additional';

export default class QuoteEstimator extends LightningElement {
    @api product;       // Opportunity Product2 record with CDN_Style_ID_SAP__c, LDP_SAP__c, etc.

    // Internal state
    estimatorProduct = null;    // matched Product2 where ProductCode = CDN_Style_ID_SAP__c
    decorationProducts = [];    // all decoration Product2 records
    selectedMainDecoration = null;
    @track selectedAdditionalDecorations = [];
    estimateResult = null;      // { totalPrice, items[] }
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
        return !this.hasEstimate;
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
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        try {
            const additionalIds = this.selectedAdditionalDecorations.map(d => d.id);
            const result = await getEstimatedPrice({
                estimatorProductId: this.estimatorProduct.Id,
                mainDecorationId: this.selectedMainDecoration,
                additionalDecorationIds: additionalIds
            });
            this.estimateResult = result;
        } catch (error) {
            this.errorMessage = this.reduceErrors(error);
            this.estimateResult = null;
        } finally {
            this.isLoading = false;
        }
    }

    handleConfirmEstimate() {
        if (!this.estimateResult) return;

        this.dispatchEvent(new CustomEvent('estimatecomplete', {
            detail: {
                estimatedUnitPrice: this.estimateResult.totalPrice,
                estimatorProductId: this.estimatorProduct.Id,
                mainDecorationId: this.selectedMainDecoration,
                additionalDecorationIds: this.selectedAdditionalDecorations.map(d => d.id),
                breakdown: this.estimateResult.items.map(item => ({
                    label: item.label,
                    price: item.price
                }))
            }
        }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    // --- Utilities ---

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
