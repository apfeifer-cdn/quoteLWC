import { LightningElement, api, wire, track } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import ToastContainer from 'lightning/toastContainer';
import Toast from 'lightning/toast';
import isProductEstimatorEnabled from '@salesforce/apex/ProductEstimatorController.isProductEstimatorEnabled';
import getQuantityOptions from '@salesforce/apex/ProductEstimatorController.getQuantityOptions';
import getDecorationOptions from '@salesforce/apex/ProductEstimatorController.getDecorationOptions';
import getProductEstimate from '@salesforce/apex/ProductEstimatorController.getProductEstimate';
import submitQuoteRequest from '@salesforce/apex/ProductEstimatorController.submitQuoteRequest';
import getShippingEstimate from '@salesforce/apex/ShippingRateController.getShippingEstimate';
import USERID from '@salesforce/user/Id';
import FIELD_ESTIMATOR_USAGE from '@salesforce/schema/Product2.Estimator__c';
import FIELD_USERNAME from '@salesforce/schema/User.Name';
import FIELD_USEREMAIL from '@salesforce/schema/User.Email';

// Price suffix when visitor is anonymous.
const ANONYMOUS_SUFFIX = ' (C)';

// Picklist values for Product2.Estimator__c.
const USAGE_ANY = 'Decoration';
const USAGE_MAIN = 'Decoration_Main';
const USAGE_ADDL = 'Decoration_Additional';

const HELP_QUANTITY = 'Enter a quantity to estimate price (minimum order quantities apply).';
const HELP_MAINDECORATION = 'Select the decoration type used on the front of the cap.';
const HELP_ADDLDECORATION = 'Select any additional decoration used on the cap.';
const HELP_DISCLAIMER = 'This is a preliminary estimate covering manufacturing and decoration only. Additional fees may apply.';
const HELP_MORE = 'Log in to request a quote or download your estimate.';

/**
 * @classdesc Lightning component to display estimator within a product page.
 * @author FuseIT for David Highfill Services
 * @since November 2025
 */
export default class ProductEstimator extends LightningElement {

    // Id of the product as supplied via parameter.
    @api
    productId;

    // When true, variations may display estimator for parent product.
    @api
    isIncludeVariations = false;

    // Redirect location for the estimate PDF.
    @api
    pdfBaseUrl = '/vforcesite/apex/ProductEstimatePdf';

    // Id of the product once verified as valid for Estimator use.
    selectedProductId;

    // General info on the current product (may be a variation of parent actually used for estimate).
    productInfo = {};

    // Options for quantity selection; upper and lower bounds, increment.
    quantityOpts;

    // Toggle to display the request quote form instead of the product input.
    showQuoteForm = false;

    // User input for request quote form.
    quoteInput = {
        name: '',
        email: '',
        details: '',
    };

    // Available main and secondary decorations (may differ).
    mainDecorationOpts = [];
    addlDecorationOpts = [];

    // True when secondary decorations are available.
    get hasSecondaryDecorations() {
        return Boolean(this.addlDecorationOpts.length);
    }

    // Expose help text to template.
    helpText = {
        qty: HELP_QUANTITY,
        mainDecoration: HELP_MAINDECORATION,
        addlDecoration: HELP_ADDLDECORATION,
        disclaimer: HELP_DISCLAIMER,
        more: HELP_MORE,
    };

    // Currently selected estimate quantity.
    _selectedQty;
    get selectedQuantity() {
        return this._selectedQty;
    }
    set selectedQuantity(val) {
        if (val !== this._selectedQty) {
            this._selectedQty = val;
            this.loadEstimate();
        }
    }

    // Currently selected main decoration.
    selectedMainDecoration;

    // Currently selected additional decorations.
    @track
    selectedAdditionalDecorations = [];
    get selectedAdditionalDecorationIds() {
        return this.selectedAdditionalDecorations.map(d => d.name);
    }

    // Estimate for current selections.
    selectionEstimate;
    
    // Error displayed to user.
    errorMessage;

    // True while retrieving data.
    isLoading = false;

    // True to calculate shipping estimate.
    isCalculateShipping = false;
    // Zip code for shipping estimate.
    shippingZip;
    // Shipping estimate data.
    shippingPrices;
    shippingOptions;
    // Selected shipping option.
    shippingSelection;
    shippingCost;
    shippingMessage;

    // True when loaded/ready to display.
    get isReady() {
        return Boolean(this.quantityOpts && this.mainDecorationOpts.length);
    }

    // Controls loading spinner.
    get isShowWorkingSpinner() {
        // If we have a product selected, but not ready for input.
        return Boolean(this.selectedProductId &&
            (this.isLoading ||
            (!this.errorMessage && !this.quantityOpts && !this.mainDecorationOpts.length)));
    }

    // True when logged in.
    get isLoggedIn() {
        return Boolean(USERID);
    }

    // True when download button should be disabled.
    get isDownloadDisabled() {
        return !Boolean(this.selectionEstimate);
    }

    // True when request quote button should be disabled.
    get isRequestQuoteDisabled() {
        return !Boolean(this.selectionEstimate);
    }

    // Test the validity of quantity input (min, max, step).
    get isQuantityValid() {
        return this.selectedQuantity && this.template.querySelector('lightning-input.estimate-qty').checkValidity();
    }

    // Grand totals for display.
    get totalPriceFormatted() {
        return this.formatPrice(this.selectionEstimate?.totalPrice ?? 0, true);
    }
    get totalQuantityFormatted() {
        return (this.selectionEstimate?.qty ?? 0).toFixed(0);
    }
    get totalFormatted() {
        const total = ((this.selectionEstimate?.totalPrice ?? 0) * (this.selectionEstimate?.qty ?? 0)) + (this.shippingCost ?? 0);
        return this.formatPrice(total, true);
    }
    get shippingCostFormatted() {
        return this.shippingCost ? this.formatPrice(this.shippingCost, true) : '';
    }

    // Name and email for logged-in users.
    @wire(getRecord, { recordId: USERID, fields: [ FIELD_USERNAME, FIELD_USEREMAIL ] })
    getUserInfo({ error, data }) {
        if (data) {
            // Set default values for request quote form.
            this.quoteInput.name = data.fields[FIELD_USERNAME.fieldApiName]?.value ?? '';
            this.quoteInput.email = data.fields[FIELD_USEREMAIL.fieldApiName]?.value ?? '';
        }
    }

    // Check if the product allows estimator use.
    @wire(isProductEstimatorEnabled, { productId: '$productId', includeVariations: '$isIncludeVariations' })
    isProductEnabled({ data, error }) {
        if (data) {
            // Returns the Id of the product configured for estimator use (may be parent of a variation).
            this.selectedProductId = data.estimateProductId;
            this.productInfo = data.productInfo;
        }
        else if (error) {
            console.log('Product estimator enabled check failed', error.body.message);
            this.errorMessage = error.body.message;
        }
    }

    // Get quantity restrictions for the product.
    @wire(getQuantityOptions, { productId: '$selectedProductId' })
    getQuantityOpts({ data, error }) {
        if (data) {
            this.quantityOpts = data;
            if (!this.selectedQuantity) {
                // Default quantity to minimum.
                this.selectedQuantity = this.quantityOpts.lowerBound;
            }
        }
        else if (error) {
            this.quantityOpts = undefined;
            console.log('Failed to retrieve quantity options', error.body.message);
            this.errorMessage = error.body.message;
        }
    }

    // Get decoration options available for the product.
    @wire(getDecorationOptions, { productId: '$selectedProductId' })
    getDecorationOpts({ data, error }) {
        if (data) {
            // Returns Product2 records; use the Estimator__c field to determine when restricted.
            const f = FIELD_ESTIMATOR_USAGE.fieldApiName;
            this.mainDecorationOpts = data.filter(p => p[f] == USAGE_ANY || p[f] == USAGE_MAIN).map(p => { return { label: p.Name, value: p.Id }; });
            this.addlDecorationOpts = data.filter(p => p[f] == USAGE_ANY || p[f] == USAGE_ADDL).map(p => { return { label: p.Name, value: p.Id }; });
        }
        else if (error) {
            this.mainDecorationOpts = [];
            this.addlDecorationOpts = [];
            console.log('Failed to retrieve decoration options', error.body.message);
            this.errorMessage = error.body.message;
        }
    }

    connectedCallback() {
        // Set up Toast container.
        const toastContainer = ToastContainer.instance();
        toastContainer.maxToasts = 3;
        toastContainer.toastPosition = 'top-center';
    }

    /**
     * Handle change of quantity selection.
     */
    quantityChange(event) {
        this.selectedQuantity = parseInt(event.target.value);
    }

    /**
     * Handle change of main decoration.
     */
    mainDecorationChange(event) {
        this.selectedMainDecoration = event.target.value;
        this.loadEstimate();
    }

    /**
     * Handle adding a new secondary decoration.
     */
    addDecorationChange(event) {
        // Should be present in our options list.
        const decorationOpt = this.addlDecorationOpts.find(d => d.value == event.target.value);
        if (decorationOpt) {
            this.selectedAdditionalDecorations.push({ name: decorationOpt.value, label: decorationOpt.label });
            this.loadEstimate();
        }
        // Clear combobox selection so that each time it adds a new pill.
        this.template.querySelector('lightning-combobox.add-decoration').value = null;
    }

    /**
     * Handle removing a secondary decoration.
     */
    removeDecoration(event) {
        // Remove from the selection list by index.
        this.selectedAdditionalDecorations.splice(event.detail.index, 1);
        this.loadEstimate();
    }

    /**
     * Handle toggle of shipping estimate display.
     */
    handleShippingToggle(event) {
        this.isCalculateShipping = event.target.checked;
        this.loadShippingEstimate();
    }

    /**
     * Handle selection of shipping estimate option.
     */
    handleShippingSelection(event) {
        this.shippingSelection = event.target.value;
        console.log('Shipping selection', this.shippingSelection);
        // Update price.
        this.shippingCost = this.shippingPrices[this.shippingSelection];
        console.log('Shipping cost', this.shippingCost);
    }

    /**
     * Handle change of Zip for shipping estimate.
     */
    handleZipChange(event) {
        this.shippingZip = event.target.value;
        this.loadShippingEstimate();
    }

    /**
     * @description Parse the current user entered zip code.
     * @returns Zip code for shipping estimate, or empty string if invalid.
     */
    parseZip() {
        // Require 5-digit zip code (automatically remove spaces and hyphens).
        const zipCode = (this.shippingZip ?? '').replaceAll(/[\s-]/g, '');
        if (zipCode.length && zipCode.match(/^\d{5}$/)) {
            // Valid.
            return zipCode;
        }
        // Invalid.
        return '';
    }

    /**
     * Perform a request to controller to get an estimate.
     */
    loadEstimate() {
        // Clear any existing estimate.
        this.selectionEstimate = undefined;
        
        // Must have a valid quantity and a main decoration.
        if (this.selectedMainDecoration && this.isQuantityValid) {
            // Enable spinner.
            this.isLoading = true;

            const promises = [
                getProductEstimate({
                    productId: this.selectedProductId,
                    quantity: this.selectedQuantity,
                    mainDecorationId: this.selectedMainDecoration,
                    additionalDecorationIds: this.selectedAdditionalDecorationIds,
                }).then(result => {
                    // Add formatting to all prices returned, plus quantity and total.
                    const items = result.items.map(item => { return {
                        ...item,
                        priceFormatted: this.formatPrice(item.itemPrice),
                        qty: result.qty.toFixed(0),
                        totalFormatted: this.formatPrice(item.itemPrice * this.selectedQuantity),
                    }; });
                    this.selectionEstimate = {
                        totalPrice: result.totalPrice,
                        items: items,
                        qty: result.qty,
                    };
                }).catch(error => {
                    console.log('Failed to retrieve estimate', error.body.message);
                    this.errorMessage = error.body.message;
                }),
                this.loadShippingEstimate(true),
            ];
            
            Promise.all(promises).finally(() => {
                // Stop spinner.
                this.isLoading = false;
            });
        }
    }

    /**
     * @description Load shipping estimate for currently selected options.
     * @param {boolean} omitSpinner True to leave the spinner as-is.
     * @returns Promise that resolves once shipping estimate is loaded.
     */
    loadShippingEstimate(omitSpinner) {
        this.shippingPrices = undefined;
        this.shippingOptions = undefined;
        this.shippingSelection = undefined;
        this.shippingCost = undefined;
        this.shippingMessage = undefined;

        // Parse entered zip code; returns empty string if not valid.
        const zipCode = this.parseZip();
        
        if (this.isCalculateShipping && zipCode.length) {
            if (!omitSpinner) {
                // Enable spinner.
                this.isLoading = true;
            }
            return getShippingEstimate({
                productId: this.selectedProductId,
                quantity: this.selectedQuantity,
                zip: zipCode,
            }).then(result => {
                if (!result.length) {
                    this.shippingMessage = 'No shipping options available';
                } else {
                    // Prices keyed by code.
                    this.shippingPrices = result.reduce((p, est) => ({ ...p, [est.serviceCode]: est.estimatedCost }), {});
                    // Options for picklist.
                    this.shippingOptions = result.map(est => { return { value: est.serviceCode, label: est.serviceName }; });
                    if (this.shippingOptions.length) {
                        // Auto-select first option.
                        this.shippingSelection = this.shippingOptions[0].value;
                        this.shippingCost = this.shippingPrices[this.shippingSelection];
                    }
                }
            }).catch(error => {
                console.log('Failed to retrieve estimate', error.body.message);
                this.shippingMessage = error.body.message;
            }).finally(() => {
                if (!omitSpinner) {
                    // Stop spinner.
                    this.isLoading = false;
                }
            });
        }

        return Promise.resolve();
    }

    /**
     * Format a number as currency.
     * @param {Number} price The price to format.
     * @returns Formatted price string.
     */
    formatPrice(price, excludeSuffix) {
        if (price) {
            // When anonymous, apply the suffix (unless explicitly disabled).
            const suffix = (this.isLoggedIn || excludeSuffix) ? '' : ANONYMOUS_SUFFIX;
            return `$${price.toFixed(2)}${suffix}`;
        }
        return '';
    }

    /**
     * Open Visualforce page to generate PDF download.
     */
    downloadPDF() {
        let pdfUrl = `${this.pdfBaseUrl}?productId=${encodeURIComponent(this.selectedProductId)}&quantity=${encodeURIComponent(this.selectedQuantity)}&mainDecorationId=${encodeURIComponent(this.selectedMainDecoration)}`;
        if (this.selectedAdditionalDecorationIds?.length) {
            pdfUrl += `&additionalDecorationIds=${encodeURIComponent(this.selectedAdditionalDecorationIds.join(','))}`;
        }
        if (this.shippingSelection) {
            pdfUrl += `&zip=${encodeURIComponent(this.shippingZip)}&shipsvc=${encodeURIComponent(this.shippingSelection)}`;
        }
        window.open(pdfUrl, '_blank');
    }

    /**
     * Handle change of value in request quote form.
     */
    quoteInputChange(event) {
        // Update property of same name in quoteInput object.
        this.quoteInput[event.target.name] = event.target.value;
    }

    /**
     * Handle click on request quote button.
     */
    requestQuote() {
        // Trigger display of request quote form.
        this.showQuoteForm = true;
    }

    /**
     * Handle click on request quote form submit button.
     */
    requestQuoteSubmit() {
        const isValid = [...this.template.querySelectorAll('lightning-input.validate')]
            .reduce((validSoFar, inputFields) => {
                inputFields.reportValidity();
                return validSoFar && inputFields.checkValidity();
            }, true);
        
        if (!isValid) {
            // Don't submit if fields are invalid.
            return;
        }
        
        submitQuoteRequest({ ...this.quoteInput, estimate: this.selectionEstimate }).then(() => {
            Toast.show({
                label: 'Success',
                message: 'Quote Request Submitted',
                mode: 'dismissable',
                variant: 'success',
            }, this);
            this.showQuoteForm = false;
        }).error(err => {
            Toast.show({
                label: 'Error',
                message: err.body.message,
                mode: 'sticky',
                variant: 'error',
            }, this);
        });
    }

}