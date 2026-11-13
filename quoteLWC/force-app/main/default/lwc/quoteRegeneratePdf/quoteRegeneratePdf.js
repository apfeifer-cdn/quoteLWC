import { LightningElement, api } from 'lwc';
import getQuotePdfBase64 from '@salesforce/apex/QuoteProductController.getQuotePdfBase64';
import regenerateQuotePdf from '@salesforce/apex/QuoteProductController.regenerateQuotePdf';

export default class QuoteRegeneratePdf extends LightningElement {
    @api recordId;
    isGenerating = false;
    toastMessage = '';
    toastVariant = '';
    showToast = false;

    async handleRegenerate() {
        this.isGenerating = true;
        this.showToast = false;

        try {
            await regenerateQuotePdf({ quoteId: this.recordId });

            const base64 = await getQuotePdfBase64({ quoteId: this.recordId });
            if (base64) {
                const binary = atob(base64);
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) {
                    bytes[i] = binary.charCodeAt(i);
                }
                const blob = new Blob([bytes], { type: 'application/pdf' });
                const url = URL.createObjectURL(blob);

                const a = document.createElement('a');
                a.href = url;
                a.download = 'Quote_' + this.recordId + '.pdf';
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                setTimeout(() => URL.revokeObjectURL(url), 1000);
            }

            this.displayToast('success', 'PDF generated and saved to this Quote.');
        } catch (e) {
            const msg = e?.body?.message || e?.message || 'An unknown error occurred.';
            this.displayToast('error', msg);
        } finally {
            this.isGenerating = false;
        }
    }

    displayToast(variant, message) {
        this.toastVariant = variant;
        this.toastMessage = message;
        this.showToast = true;
    }

    get toastClass() {
        const base = 'slds-notify slds-notify_toast';
        return this.toastVariant === 'error'
            ? base + ' slds-theme_error'
            : base + ' slds-theme_success';
    }

    get buttonLabel() {
        return this.isGenerating ? 'Generating...' : 'Regenerate PDF';
    }
}
