/**
 * @description Controller for ProductEstimator Lightning component and Visualforce page used in web store.
 * @author FuseIT for David Highfill Services
 * @since November 2025
 */
public with sharing class ProductEstimatorController {
    
    //#region Constants
    
    /**
     * Key used to load the WebStoreId.
     */
    @testVisible
    private static final String WEBSTORE_NAME = 'Shop';

    // Picklist values for Product2.Estimator__c.
    @testVisible
    private static final String ESTIMATOR_PRODUCT = 'Product';
    @testVisible
    private static final String ESTIMATOR_DECORATION_ANY = 'Decoration';
    @testVisible
    private static final String ESTIMATOR_DECORATION_MAIN = 'Decoration_Main';
    @testVisible
    private static final String ESTIMATOR_DECORATION_ADDL = 'Decoration_Additional';

    // Subject for Tasks created to request quote.
    public static final String QUOTE_REQUEST_SUBJECT = 'Quote Request';

    //#endregion

    //#region Properties

    // Result objects for use in Apex tests.
    @testVisible
    private static Map<String, ConnectApi.ProductOverview> testProducts;
    @testVisible
    private static Map<String, ConnectApi.ProductPrice> testPrices;

    // Test Contact for Quote request Tasks.
    @testVisible
    private static Id testContactId = null;

    // Parameters for Visualforce page.
    public String productId { get; set; }
    public Integer quantity { get; set; }
    public String mainDecorationId { get; set; }
    public List<String> additionalDecorationIds { get; set; }
    public Date estimateDate { get; private set; }
    public String shippingZip { get; private set; }
    public String shippingServiceCode { get; private set; }

    // Visualforce output.
    public EstimatePrice estimate { get; private set; }
    public ConnectApi.ProductOverview productInfo { get; private set; }
    public String error { get; private set; }
    public String contactEmail { get; private set; }
    public List<UpsRatingService.RatingResult> shipping { get; private set; }

    //#endregion

    //#region Constructors

    // Visualforce use only; LWC only uses static methods.
    public ProductEstimatorController() {
        productId = ApexPages.currentPage().getParameters().get('productId');
        quantity = Integer.valueOf(ApexPages.currentPage().getParameters().get('quantity') ?? '0');
        mainDecorationId = ApexPages.currentPage().getParameters().get('mainDecorationId');
        String addlIds = ApexPages.currentPage().getParameters().get('additionalDecorationIds');
        additionalDecorationIds = String.isNotBlank(addlIds) ? addlIds.split(',') : null;
        estimateDate = System.today();
        shippingZip = ApexPages.currentPage().getParameters().get('zip');
        shippingServiceCode = ApexPages.currentPage().getParameters().get('shipsvc');
        shipping = new List<UpsRatingService.RatingResult>();
    }

    //#endregion

    //#region Controller Methods

    /**
     * @description Visualforce action method to generate estimate output.
     */
    public PageReference generatePDF() {
        try {
            estimate = getProductEstimate(productId, quantity, mainDecorationId, additionalDecorationIds);
            productInfo = getProductInfo(productId, getWebStoreId(), true);
            // Get email of Contact Owner; note this requires permission to access the User.
            List<User> contactInfo = [SELECT Contact.ContactOwnerEmail__c FROM User WHERE Id = :UserInfo.getUserId()];
            contactEmail = contactInfo.isEmpty() ? '' : (contactInfo[0].Contact?.ContactOwnerEmail__c ?? '');
            if (String.isNotBlank(shippingZip) && String.isNotBlank(shippingServiceCode)) {
                List<UpsRatingService.RatingResult> shipopts = ShippingRateController.getShippingEstimate(productId, quantity, shippingZip);
                for (UpsRatingService.RatingResult shipopt : shipopts) {
                    if (shipopt.serviceCode == shippingServiceCode) {
                        shipping.add(shipopt);
                        break;
                    }
                }
            }
        }
        catch (Exception ex) {
            error = ex.getMessage();
        }
        return null;
    }

    /**
     * @description Check whether the estimator should be enabled for a given product.
     * @param productId The Id of the current Product2.
     * @param includeVariations True to allow use of a direct variant parent, if enabled.
     * @return Object containing the Id of the enabled Product2 (current or parent where applicable) along with general info, or null to disable.
     */
    @AuraEnabled(cacheable=true)
    public static EstimateProductInfo isProductEstimatorEnabled(Id productId, Boolean includeVariations) {
        if (productId == null) {
            return null;
        }
        
        try {
            // Get the overview info for the directly-requested product (if this throws an exception then the user doesn't have access or the request is invalid).
            ConnectApi.ProductOverview info = getProductInfo(productId, getWebStoreId(), false);
            
            List<Product2> products = [
                SELECT Id, Estimator__c,
                    (SELECT Id, VariantParentId, VariantParent.Estimator__c FROM ProductAttributes WHERE VariantParent.Estimator__c = :ESTIMATOR_PRODUCT)
                FROM Product2 WHERE Id = :productId
            ];
            if (!products.isEmpty() && products[0].Estimator__c == ESTIMATOR_PRODUCT) {
                // Main product is configured for estimator use.
                return new EstimateProductInfo(products[0].Id, info);
            }
            else if (includeVariations && !products.isEmpty() && products[0].ProductAttributes != null && !products[0].ProductAttributes.isEmpty()) {
                // Parent product is configured for estimator use.
                return new EstimateProductInfo(products[0].ProductAttributes[0].VariantParentId, info);
            }
            return null;
        }
        catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    /**
     * @description Get quantity restrictions.
     * @param productId The main product being used in the estimator.
     * @return Object containing restriction info.
     */
    @AuraEnabled(cacheable=true)
    public static EstimateQuantityRange getQuantityOptions(Id productId) {
        try {
            // Get quantity rule for product.
            ConnectApi.ProductOverview product = getProductInfo(productId, getWebStoreId(), false);

            if (product.purchaseQuantityRule == null) {
                // No quantity rule; return all-encompassing limits.
                return new EstimateQuantityRange(1, 2147483647, 1);
            }
            
            // Extract min, max and increment (all required values on the record, returned as string from Connect API call).
            return new EstimateQuantityRange(
                Integer.valueOf(product.purchaseQuantityRule.minimum),
                Integer.valueOf(product.purchaseQuantityRule.maximum),
                Integer.valueOf(product.purchaseQuantityRule.increment)
            );
        }
        catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    /**
     * @description Get available decoration products.
     * @param productId The Id of the main Product2.
     * @return List of Product2 records configured as available decorations.
     */
    @AuraEnabled(cacheable=true)
    public static List<Product2> getDecorationOptions(Id productId) {
        try {
            // The API values for Product2.Estimator_Decorations__c should be the Product Codes of the applicable decoration Products.
            List<Product2> products = [SELECT Id, Estimator_Decorations__c FROM Product2 WHERE Id = :productId AND Estimator__c = :ESTIMATOR_PRODUCT];
            List<String> decorationProductCodes = products.isEmpty() ? new List<String>() : products[0].Estimator_Decorations__c.split(';');
            List<String> decorationUsage = new List<String> { ESTIMATOR_DECORATION_ANY, ESTIMATOR_DECORATION_MAIN, ESTIMATOR_DECORATION_ADDL };
            products = [SELECT Id, Name, Estimator__c FROM Product2 WHERE ProductCode IN :decorationProductCodes AND Estimator__c IN :decorationUsage];
            if (products.isEmpty()) {
                throw new EstimatorException('No decoration options found for product');
            }
            return products;
        }
        catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }
    
    /**
     * @description Get product estimate details.
     * @param productId The Id of the main Product2.
     * @param quantity Quantity for estimate.
     * @param mainDecorationId The Id of the main decoration Product2.
     * @param additionalDecorationIds Additional Product2 Ids for secondary decorations.
     * @return Object containing estimate details.
     * @see https://developer.salesforce.com/docs/atlas.en-us.apexref.meta/apexref/apex_ConnectAPI_CommerceStorePricing_static_methods.htm
     */
    @AuraEnabled(cacheable=true)
    public static EstimatePrice getProductEstimate(Id productId, Integer quantity, String mainDecorationId, List<String> additionalDecorationIds) {
        try {
            // Validation/sanity checks.
            if (productId == null) {
                throw new EstimatorException('A value is required for productId');
            }
            if (mainDecorationId == null) {
                throw new EstimatorException('A value is required for mainDecorationId');
            }
            Id webStoreId = getWebStoreId();
            if (webStoreId == null) {
                throw new EstimatorException('Unable to determine WebStoreId');
            }
            if (quantity == null || quantity <= 0) {
                System.debug(LoggingLevel.WARN, 'Invalid quantity supplied, defaulting to 1.');
                quantity = 1;
            }
            
            Decimal decorationPrice;
            String decorationName;
            EstimatePrice result = new EstimatePrice();
            
            // Note we cannot use CommerceStorePricing.getProductPrices() to get all at once as it doesn't return tiered pricing info.
            ConnectApi.ProductPrice price = getProductPrice(productId, webStoreId);
            result.qty = quantity;
            result.totalPrice += getPriceForQuantity(price, quantity);
            System.debug(LoggingLevel.DEBUG, 'Base product ' + productId + ' price: ' + result.totalPrice);
            String baseProductName = getProductInfo(productId, webStoreId, false).name;

            // Main decoration allows optional overriding of price with a custom record.
            List<Product_Estimator_Decoration__c> mainDecorations = [
                SELECT Id, Override_Price__c, Product__r.Name FROM Product_Estimator_Decoration__c
                WHERE Product__c = :productId AND Decoration__c = :mainDecorationId
                    AND Price_Book__c IN (SELECT Pricebook2Id FROM PricebookEntry WHERE Id = :price.pricebookEntryId)
                    AND (Quantity_Lower_Bound__c = null OR Quantity_Lower_Bound__c <= :quantity)
                    AND (Quantity_Upper_Bound__c = null OR Quantity_Upper_Bound__c >= :quantity)
            ];
            if (!mainDecorations.isEmpty()) {
                // Overridden price exists, use it.
                decorationPrice = mainDecorations[0].Override_Price__c;
                System.debug(LoggingLevel.DEBUG, 'Main decoration ' + mainDecorationId + ' has override price: ' + decorationPrice + '.');
                decorationName = mainDecorations[0].Product__r.Name;
            }
            else {
                // No overridden price, get main decoration direct from pricebook.
                price = getProductPrice(mainDecorationId, webStoreId);
                decorationPrice = getPriceForQuantity(price, quantity);
                System.debug(LoggingLevel.DEBUG, 'Main decoration ' + mainDecorationId + ' price from pricebook: ' + decorationPrice + '.');
                decorationName = getProductInfo(mainDecorationId, webStoreId, false).name;
            }
            result.totalPrice += decorationPrice;
            result.items.add(new EstimateItem(baseProductName + ' with ' + decorationName, result.totalPrice));

            // Add secondary decorations.
            for (String decorationId : additionalDecorationIds ?? new List<String>()) {
                price = getProductPrice(decorationId, webStoreId);
                decorationPrice = getPriceForQuantity(price, quantity);
                decorationName = getProductInfo(decorationId, webStoreId, false).name;
                result.totalPrice += decorationPrice;
                result.items.add(new EstimateItem(decorationName, decorationPrice));
                System.debug(LoggingLevel.DEBUG, 'Additional decoration ' + decorationId + ' price from pricebook: ' + decorationPrice + '.');
            }

            System.debug(LoggingLevel.DEBUG, 'Total unit price for estimate: ' + result.totalPrice + '.');
            return result;
        }
        catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    /**
     * @description Submit a quote request for an estimate.
     * @param name Name of the person requesting the quote.
     * @param email Email address to respond to.
     * @param details Optional additional details/comments.
     * @param estimate Compiled estimate information.
     */
    @AuraEnabled(cacheable=false)
    public static void submitQuoteRequest(String name, String email, String details, EstimatePrice estimate) {
        try {
            // Concatenate estimate info with user request.
            String comments =
                name + ' (' + email + ')'
                + '\n\n' + estimate.toString()
                + (String.isNotBlank(details) ? ('\n\nUser request: ' + details) : '');
            
            // Get Contact associated with current User (should be a community user).
            List<User> users = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId()];
            if ((!Test.isRunningTest() && (users.isEmpty() || users[0].ContactId == null)) || (Test.isRunningTest() &&testContactId == null)) {
                throw new EstimatorException('Unable to determine Contact for logged-in user.');
            }
            
            // Create as a Task; automation should detect new Tasks by subject and process from there.
            insert new Task(
                Subject = QUOTE_REQUEST_SUBJECT,
                WhoId = Test.isRunningTest() ? testContactId : users[0].ContactId,
                Description = comments
            );
        }
        catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, ex.getMessage());
            throw new AuraHandledException(ex.getMessage());
        }
    }

    //#endregion

    //#region Private Methods

    /**
     * @description Get general information for a product, specific to the web store.
     * @param productId The Product2.Id.
     * @param webStoreId The WebStore.Id.
     * @param includeImage True to retrieve image information, false to exclude.
     * @return ProductOverview object.
     * @exception If not found.
     */
    private static ConnectApi.ProductOverview getProductInfo(String productId, String webStoreId, Boolean includeImage) {
        ConnectApi.ProductOverviewCollection data;
        if (Test.isRunningTest()) {
            data = new ConnectApi.ProductOverviewCollection();
            data.products = new List<ConnectApi.ProductOverview> {
                testProducts != null && testProducts.containsKey(productId) ? testProducts.get(productId) : null
            };
        }
        else {
            data = ConnectApi.CommerceCatalog.getProducts(webStoreId, null, new List<String> { productId },
                null, new List<String> { 'Id' }, !includeImage, true, false, false, false, 'false');
        }

        if (data.products.isEmpty()) {
            throw new EstimatorException('Failed to retrieve product information');
        }
        return data.products[0];
    }

    /**
     * @description Get price information for a product, specific to the web store.
     * @param productId The Product2.Id.
     * @param webStoreId The WebStore.Id.
     * @return ProductPrice object.
     */
    private static ConnectApi.ProductPrice getProductPrice(String productId, String webStoreId) {
        ConnectApi.ProductPrice data;
        if (Test.isRunningTest()) {
            data = testPrices != null && testPrices.containsKey(productId) ? testPrices.get(productId) : null;
        }
        else {
            data = ConnectApi.CommerceStorePricing.getProductPrice(webStoreId, productId, null);
        }
        return data;
    }

    /**
     * @description Get quantity-specific price for a product.
     * @param price Loaded price information.
     * @param quantity The selected quantity.
     * @return Tiered price applicable, or list price if none.
     */
    private static Decimal getPriceForQuantity(ConnectApi.ProductPrice price, Integer quantity) {
        for (ConnectApi.PriceAdjustmentTier tier : price.priceAdjustment?.priceAdjustmentTiers ?? new List<ConnectApi.PriceAdjustmentTier>()) {
            if (Integer.valueOf(tier.lowerBound ?? '0') <= quantity && Integer.valueOf(tier.upperBound ?? quantity.toString()) >= quantity) {
                System.debug(LoggingLevel.DEBUG, 'PricebookEntryId ' + price.pricebookEntryId + ': found tierUnitPrice ' + tier.tierUnitPrice + ' for quantity ' + quantity + '.');
                return Decimal.valueOf(tier.tierUnitPrice);
            }
        }

        // Fall back to standard unit price if no matching quantity tier found.
        System.debug(LoggingLevel.DEBUG, 'PricebookEntryId ' + price.pricebookEntryId + ': tierUnitPrice for quantity ' + quantity + ' not found, using standard unitPrice ' + price.unitPrice + '.');
        return Decimal.valueOf(price.unitPrice);
    }

    /**
     * @description Get the Id of the shop web store.
     * @return WebStore.Id value.
     */
    private static Id getWebStoreId() {
        List<WebStore> stores = [SELECT Id FROM WebStore WHERE Name = :WEBSTORE_NAME];
        return stores.isEmpty() ? null : stores[0].Id;
    }

    //#endregion

    //#region Subclasses

    /**
     * Structure for initial product response.
     */
    public class EstimateProductInfo {
        @AuraEnabled
        public String estimateProductId { get; set; }
        @AuraEnabled
        public ConnectApi.ProductOverview productInfo { get; set; }

        public EstimateProductInfo() { }

        public EstimateProductInfo(String productId, ConnectApi.ProductOverview info) {
            estimateProductId = productId;
            productInfo = info;
        }
    }

    /**
     * Structure for quantity options.
     */
    public class EstimateQuantityRange {
        @AuraEnabled
        public Integer lowerBound { get; set; }
        @AuraEnabled
        public Integer upperBound { get; set; }
        @AuraEnabled
        public Integer increment { get; set; }

        public EstimateQuantityRange(Integer lower, Integer upper, Integer inc) {
            lowerBound = lower;
            upperBound = upper;
            increment = inc;
        }
    }

    /**
     * Structure for estimate details.
     */
    public class EstimatePrice {
        @AuraEnabled
        public Integer qty { get; set; }
        @AuraEnabled
        public Decimal totalPrice { get; set; }
        @AuraEnabled
        public List<EstimateItem> items { get; set; }

        public EstimatePrice() {
            items = new List<EstimateItem>();
            totalPrice = 0;
        }

        public override String toString() {
            String output = '';
            for (EstimateItem item : items) {
                output += item.toString() + '\n';
            }
            return output + 'Quantity: ' + qty + ', Total Unit Price: ' + totalPrice;
        }
    }

    /**
     * Structure for individual items within an estimate.
     */
    public class EstimateItem {
        @AuraEnabled
        public String itemLabel { get; set; }
        @AuraEnabled
        public Decimal itemPrice { get; set; }

        public EstimateItem() { }

        public EstimateItem(String label, Decimal price) {
            itemLabel = label;
            itemPrice = price;
        }

        public override String toString() {
            return itemLabel + ': ' + itemPrice;
        }
    }

    /**
     * Custom exceptions.
     */
    public class EstimatorException extends Exception { }

    //#endregion

}