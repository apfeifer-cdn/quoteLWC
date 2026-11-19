public class ProductImageController {

    public Quote PIC_Quote { get; set; }
    public Id quoteId { get; set; }
    public List<QuoteLineItem> QuoteLineItems { get; set; }

    //Use a Map of Products to prevent hitting SOQL limits
    public Map<Id,Product2> MapProducts { get; set; }

    //List of ProductModels to render the correct image for the product
    public List<ProductModel> ProductModels { get; set; }

    // Tier visibility flags — true when tier falls within user-selected min/max range
    public Boolean has50112 { get; set; }
    public Boolean has20016 { get; set; }
    public Boolean has10080 { get; set; }
    public Boolean has5040 { get; set; }
    public Boolean has2592 { get; set; }
    public Boolean has1008 { get; set; }
    public Boolean has576 { get; set; }
    public Boolean has288 { get; set; }
    public Boolean has144 { get; set; }
    public Boolean has72 { get; set; }

    //map of latest ContentVersion records for ProductIds
    public Map<Id, ContentVersion> ProductFileMap { get; set; }

    public ProductImageController(ApexPages.StandardController controller) {
        // Query Quote with tier range fields
        PIC_Quote = [
            SELECT Id, Min_Quantity_Tier__c, Max_Quantity_Tier__c
            FROM Quote
            WHERE Id = :controller.getId()
        ];
        
        QuoteLineItems = [
            SELECT Product2.Id, Product2.Name, Product2.ProductCode, Product2.Description, Product2.ProductClass,
                Product2.Special_Program_SAP__c,
                Mold_Charge__c, COO__c, COO_Override__c, Custom_Description__c,
                Ocean_Leadtime__c, Air_Lead_Time__c, X2592_Ocean_Currency__c, X5040_Ocean_Currency__c, X10080_Ocean_Currency__c, X20016_Ocean_Currency__c, X50112_Ocean_Currency__c, X1008_Ocean_Currency__c, X1008_Air_Currency__c, X576_Ocean_Currency__c,
                X576_Air_Currency__c, X288_Ocean_Currency__c, X288_Air_Currency__c, X144_Ocean_Currency__c, X144_Air_Currency__c,
                X72_Ocean_Currency__c, Product2.Image_SAP__c, Product2.Thumbnail_SAP__c
            FROM QuoteLineItem
            WHERE QuoteId = :PIC_Quote.Id
        ];

        //create a set of Product IDs
        Set<Id> productIds = new Set<Id>();
        for (QuoteLineItem item : QuoteLineItems) {
            productIds.add(item.Product2.Id);
        }

        //get a map of Products
        MapProducts = new Map<Id,Product2>([
            SELECT Image_SAP__c, Thumbnail_SAP__c 
            FROM Product2 
            WHERE Id IN :productIds
        ]);

        //get a map of existing ContentVersion records for the ProductIds
        ProductFileMap = getLatestFileVersionsForProducts(productIds);
        System.debug(ProductFileMap);

        ProductModels = new List<ProductModel>();

        //build the list of ProductModels
        for (QuoteLineItem item : QuoteLineItems) {
            ProductModel pm = new ProductModel();

            pm.Name = item.Product2.Name;
            pm.ProductCode = item.Product2.ProductCode;
            pm.Description = item.Product2.Description;
            // The quote tool saves the custom description to Product2.Description, so the
            // two are normally identical. Print the text once.
            pm.Custom_Description = isSameText(item.Custom_Description__c, item.Product2.Description)
                ? null : item.Custom_Description__c;
            pm.Mold_Charge = item.Mold_Charge__c;
            pm.COO = String.isNotBlank(item.COO_Override__c)
                ? item.COO_Override__c : item.COO__c;
            pm.Ocean_Leadtime = item.Ocean_Leadtime__c;
            pm.Air_Lead_Time = item.Air_Lead_Time__c;
            pm.X50112_Ocean_Currency = item.X50112_Ocean_Currency__c;
            pm.X20016_Ocean_Currency = item.X20016_Ocean_Currency__c;
            pm.X10080_Ocean_Currency = item.X10080_Ocean_Currency__c;
            pm.X5040_Ocean_Currency = item.X5040_Ocean_Currency__c;
            pm.X2592_Ocean_Currency = item.X2592_Ocean_Currency__c;
            pm.X1008_Ocean_Currency = item.X1008_Ocean_Currency__c;
            pm.X1008_Air_Currency = item.X1008_Air_Currency__c;
            pm.X576_Ocean_Currency = item.X576_Ocean_Currency__c;
            pm.X576_Air_Currency = item.X576_Air_Currency__c;
            pm.X288_Ocean_Currency = item.X288_Ocean_Currency__c;
            pm.X288_Air_Currency = item.X288_Air_Currency__c;
            pm.X144_Ocean_Currency = item.X144_Ocean_Currency__c;
            pm.X144_Air_Currency = item.X144_Air_Currency__c;
            pm.X72_Ocean_Currency = item.X72_Ocean_Currency__c;

            // Ocean/Air split applies to all non-Quick products (Simple and VariationParent).
            // Quick products display only the user-selected lead time and no Air column.
            String productClass = item.Product2.ProductClass;
            String specialProgram = item.Product2.Special_Program_SAP__c;
            // North American Custom (special program QuickTurnNAC) is presented like Quick Turn:
            // one lead time and no Air prices.
            Boolean isQuick = QuoteCostService.isQuickProgram(specialProgram)
                || QuoteCostService.isNorthAmericanCustom(specialProgram);
            pm.ShowAir = !isQuick;
            pm.IsQuick = isQuick;

            pm.ImageURL = getValidImageUrl(item.Product2.Id);

            //if there is a product file, then set the ContentVersionId
            if (ProductFileMap.containsKey(item.Product2.Id)) {
                pm.ContentVersionId = ProductFileMap.get(item.Product2.Id).Id;
            }

            ProductModels.add(pm);
        }

        System.debug(ProductModels);

        // Determine which tier columns to show based on min/max range stored on Quote
        Integer minQty = PIC_Quote.Min_Quantity_Tier__c != null
            ? PIC_Quote.Min_Quantity_Tier__c.intValue() : 0;
        Integer maxQty = PIC_Quote.Max_Quantity_Tier__c != null
            ? PIC_Quote.Max_Quantity_Tier__c.intValue() : 999999;
        // Handle swapped values defensively
        Integer rangeMin = Math.min(minQty, maxQty);
        Integer rangeMax = Math.max(minQty, maxQty);

        has144   = (144   >= rangeMin && 144   <= rangeMax);
        has72    = (72    >= rangeMin && 72    <= rangeMax);
        has288   = (288   >= rangeMin && 288   <= rangeMax);
        has576   = (576   >= rangeMin && 576   <= rangeMax);
        has1008  = (1008  >= rangeMin && 1008  <= rangeMax);
        has2592  = (2592  >= rangeMin && 2592  <= rangeMax);
        has5040  = (5040  >= rangeMin && 5040  <= rangeMax);
        has10080 = (10080 >= rangeMin && 10080 <= rangeMax);
        has20016 = (20016 >= rangeMin && 20016 <= rangeMax);
        has50112 = (50112 >= rangeMin && 50112 <= rangeMax);
    }

    // Return the first valid image URL or null if none found
    public String getValidImageUrl(Id productId) {
        Product2 product = MapProducts.get(productId);

        // Check Thumbnail first
        if (!String.isBlank(product.Thumbnail_SAP__c)) {
            if (isValidImageUrl(product.Thumbnail_SAP__c)) {
                return product.Thumbnail_SAP__c;
            }
        }

        // Fall back to full Image_SAP if Thumbnail is missing or invalid
        if (!String.isBlank(product.Image_SAP__c)) {
            if (isValidImageUrl(product.Image_SAP__c)) {
                return product.Image_SAP__c;
            }
        }

        // Fall back to ContentVersion if both SAP URLs are invalid
        if (ProductFileMap.containsKey(productId)) {
            ContentVersion cv = ProductFileMap.get(productId);
            // Note: this URL requires auth - consider base64 data URI approach for PDF rendering
            return '/sfc/servlet.shepherd/version/download/' + cv.Id;
        }

        return null;
    }

    // Returns true if the URL responds with HTTP 200
    private Boolean isValidImageUrl(String imageUrl) {
        try {
            Http http = new Http();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(imageUrl);
            req.setMethod('GET');
            req.setTimeout(5000);
            HttpResponse res = http.send(req);
            return res.getStatusCode() == 200;
        } catch (Exception e) {
            System.debug('Error checking image URL: ' + e.getMessage());
            return false;
        }
    }

    // Get the latest ContentVersion records for a set of Product IDs
    /** True when both texts are non-blank and equal, ignoring line-ending and outer whitespace differences. */
    @TestVisible
    private static Boolean isSameText(String first, String second) {
        if (String.isBlank(first) || String.isBlank(second)) {
            return false;
        }
        return first.replace('\r\n', '\n').trim() == second.replace('\r\n', '\n').trim();
    }

    public static Map<Id, ContentVersion> getLatestFileVersionsForProducts(Set<Id> productIds) {
        Map<Id, ContentVersion> mapProductContentVersions = new Map<Id, ContentVersion>();

        System.debug('productIds: ' + productIds);

        if (productIds == null || productIds.isEmpty()) {
            return mapProductContentVersions;
        }

        //Get ContentDocument IDs linked to Products
        Map<Id, Id> productToDocumentMap = new Map<Id, Id>();
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, LinkedEntityId, ContentDocument.FileType, ContentDocument.CreatedDate, ContentDocument.Title 
            FROM ContentDocumentLink 
            WHERE LinkedEntityId IN :productIds
            AND ContentDocument.FileType IN ('JPG', 'PNG')
            ORDER BY ContentDocument.CreatedDate
        ];

        for (ContentDocumentLink link : links) {
            productToDocumentMap.put(link.LinkedEntityId, link.ContentDocumentId);
        }

        //Get the latest ContentVersion using IsLatest = TRUE
        if (!productToDocumentMap.isEmpty()) {
            List<ContentVersion> latestVersions = [
                SELECT Id, Title, FileExtension, ContentDocumentId 
                FROM ContentVersion 
                WHERE ContentDocumentId IN :productToDocumentMap.values()
                AND IsLatest = TRUE
            ];

            //Map Product ID to ContentVersion using ContentDocumentId
            Map<Id, ContentVersion> documentToVersionMap = new Map<Id, ContentVersion>();
            for (ContentVersion version : latestVersions) {
                documentToVersionMap.put(version.ContentDocumentId, version);
            }

            for (Id productId : productToDocumentMap.keySet()) {
                Id documentId = productToDocumentMap.get(productId);
                if (documentToVersionMap.containsKey(documentId)) {
                    mapProductContentVersions.put(productId, documentToVersionMap.get(documentId));
                }
            }
        }

        return mapProductContentVersions;
    }

    //For rendering the correct image on the page
    public class ProductModel {

        public String Name { get; set; }
        public String ProductCode { get; set; }
        public String Description { get; set; }
        public String Custom_Description { get; set; }
        public Decimal Mold_Charge { get; set; }
        public String COO { get; set; }
        public String Ocean_Leadtime { get; set; }
        public String Air_Lead_Time { get; set; }
        public Decimal X50112_Ocean_Currency { get; set; }
        public Decimal X20016_Ocean_Currency { get; set; }
        public Decimal X10080_Ocean_Currency { get; set; }
        public Decimal X5040_Ocean_Currency { get; set; }
        public Decimal X2592_Ocean_Currency { get; set; }
        public Decimal X1008_Ocean_Currency { get; set; }
        public Decimal X1008_Air_Currency { get; set; }
        public Decimal X576_Ocean_Currency { get; set; }
        public Decimal X576_Air_Currency { get; set; }
        public Decimal X288_Ocean_Currency { get; set; }
        public Decimal X288_Air_Currency { get; set; }
        public Decimal X144_Ocean_Currency { get; set; }
        public Decimal X144_Air_Currency { get; set; }
        public Decimal X72_Ocean_Currency { get; set; }
        public Boolean ShowAir { get; set; }
        public Boolean IsQuick { get; set; }
        public String ImageURL { get; set; }
        public String ContentVersionId { get; set; }

    }

}
