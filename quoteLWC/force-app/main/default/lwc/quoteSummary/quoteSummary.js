import { LightningElement, api } from 'lwc';

export default class QuoteSummary extends LightningElement {
    _selectedProducts = [];

    @api
    get selectedProducts() {
        return this._selectedProducts;
    }

    set selectedProducts(value) {
        // showAir: Air price and Air margin columns. Quick Turn and North American
        // Custom lines never show them. Older entries without the flag fall back to
        // the Quick check.
        this._selectedProducts = (value || []).map(product => ({
            ...product,
            showAir: product.showAir != null ? product.showAir : !product.isQuickProduct
        }));
    }

    get hasProducts() {
        return this._selectedProducts.length > 0;
    }

    handleRemoveProduct(event) {
        const productId = event.currentTarget.dataset.productId;
        this.dispatchEvent(new CustomEvent('removequoteproduct', {
            detail: { productId }
        }));
    }

    handleSubmitQuote() {
        this.dispatchEvent(new CustomEvent('submitquote'));
    }

    handleGoBack() {
        this.dispatchEvent(new CustomEvent('goback'));
    }
}
