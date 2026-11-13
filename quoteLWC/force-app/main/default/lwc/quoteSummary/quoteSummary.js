import { LightningElement, api } from 'lwc';

export default class QuoteSummary extends LightningElement {
    @api selectedProducts = [];

    get hasProducts() {
        return this.selectedProducts && this.selectedProducts.length > 0;
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
