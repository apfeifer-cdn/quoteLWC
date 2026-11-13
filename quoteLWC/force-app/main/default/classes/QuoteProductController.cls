public with sharing class QuoteProductController {

    public class TierConfig implements Comparable {
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal sortOrder;
        @AuraEnabled public Boolean isBaseTier;
        @AuraEnabled public String adjustmentType;
        @AuraEnabled public Decimal dollarAdjustment;
        @AuraEnabled public Decimal percentDiscount;

        public Integer compareTo(Object other) {
            TierConfig otherTier = (TierConfig) other;
            if (this.sortOrder == otherTier.sortOrder) return 0;
            if (this.sortOrder > otherTier.sortOrder) return 1;
            return -1;
        }
    }

    public class QuoteLineItemData {
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal ldp;
        @AuraEnabled public Decimal moldCharge;
        @AuraEnabled public String coo;
        @AuraEnabled public String oceanLeadtime;
        @AuraEnabled public String airLeadTime;
        @AuraEnabled public Boolean isQuickProduct;
        @AuraEnabled public String customDescription;
        @AuraEnabled public Map<String, Decimal> tierPrices;
        // Estimated LDP per quantity tier, keyed by quantity ("144"). Internal only.
        @AuraEnabled public Map<String, Decimal> tierLdps;
    }

    public class QuoteRequest {
        @AuraEnabled public String opportunityId;
        @AuraEnabled public Decimal minQuantity;
        @AuraEnabled public Decimal maxQuantity;
        @AuraEnabled public String expirationDate;
        @AuraEnabled public List<QuoteLineItemData> lineItems;
    }

    // Not cacheable: Product2.Description is written when a quote is created and the
    // next quote must read the saved value, not a client-side cached copy.
    @AuraEnabled
    public static List<Product2> getProducts(String opportunityId) {
        Set<Id> productIds = new Set<Id>();

        for (OpportunityLineItem oli : [
            SELECT Product2Id FROM OpportunityLineItem WHERE OpportunityId = :opportunityId
        ]) {
            productIds.add(oli.Product2Id);
        }

        List<Product2> allProducts = [
            SELECT Id, Name, ProductCode, Description, ProductClass,
                   LDP_SAP__c, LDP_144_SAP__c, LDP_288_SAP__c, LDP_432_SAP__c,
                   Opportunity_ID_SAP__c,
                   Special_Program_SAP__c, CDN_Style_ID_SAP__c,
                   Account__c, Account__r.Name, Account__r.Base_Margin_SAP__c,
                   Manufacturer__c, Manufacturer__r.Name,
                   Manufacturer__r.X144_Air_Rate__c,
                   Manufacturer__r.X288_Air_Rate__c,
                   Manufacturer__r.X576_Air_Rate__c,
                   Manufacturer__r.X1008_Air_Rate__c,
                   Image_SAP__c, Thumbnail_SAP__c
            FROM Product2
            WHERE (Opportunity_ID_SAP__c = :opportunityId OR Id IN :productIds)
              AND (ProductClass = 'Simple' OR ProductClass = 'VariationParent')
            ORDER BY Name ASC
        ];

        // Deduplicate by ProductCode.
        // Quick products: keep Simple only.
        // Non-Quick: prefer VariationParent over Simple.
        Map<String, Product2> deduped = new Map<String, Product2>();
        for (Product2 p : allProducts) {
            if (String.isBlank(p.ProductCode)) continue;

            Boolean isQuick = p.Special_Program_SAP__c != null
                && p.Special_Program_SAP__c.toLowerCase().contains('quick');

            if (isQuick && p.ProductClass != 'Simple') continue;

            Product2 existing = deduped.get(p.ProductCode);
            if (existing == null) {
                deduped.put(p.ProductCode, p);
            } else if (!isQuick && p.ProductClass == 'VariationParent'
                       && existing.ProductClass == 'Simple') {
                deduped.put(p.ProductCode, p);
            }
        }

        List<String> sortedCodes = new List<String>(deduped.keySet());
        sortedCodes.sort();
        List<Product2> result = new List<Product2>();
        for (String code : sortedCodes) {
            result.add(deduped.get(code));
        }
        return result;
    }

    /**
     * Looks up a PriceAdjustmentSchedule whose name contains both the caller-supplied
     * fragment and the word "net", then returns the dollar adjustment for tier 72.
     * Used by productPricingCard to auto-populate tier 72 pricing for Simple products.
     * Returns null if input is blank, no schedule matches, or no tier 72 row exists.
     */
    @AuraEnabled(cacheable=true)
    public static Decimal getTier72Adjustment(String scheduleNameInput) {
        if (String.isBlank(scheduleNameInput)) {
            return null;
        }

        String searchPattern = '%' + scheduleNameInput + '%';
        List<PriceAdjustmentSchedule> schedules = [
            SELECT Id, Name
            FROM PriceAdjustmentSchedule
            WHERE Name LIKE :searchPattern AND Name LIKE '%net%'
            LIMIT 1
        ];

        if (schedules.isEmpty()) {
            return null;
        }

        List<PriceAdjustmentTier> tiers = [
            SELECT Id, LowerBound, TierValue
            FROM PriceAdjustmentTier
            WHERE PriceAdjustmentScheduleId = :schedules[0].Id
              AND LowerBound = 72
            LIMIT 1
        ];

        if (tiers.isEmpty()) {
            return null;
        }

        return tiers[0].TierValue;
    }

    // Test seams: allow Apex tests to inject tier metadata when running in environments
    // where the Quantity_Tier__mdt / Tier_Adjustment__mdt records may not be deployed.
    // Production code paths leave these null and the method reads from the actual metadata.
    @TestVisible
    private static List<Quantity_Tier__mdt> tierConfigOverride;
    @TestVisible
    private static List<Tier_Adjustment__mdt> tierAdjustmentOverride;

    @AuraEnabled(cacheable=true)
    public static List<TierConfig> getTierConfig() {
        Map<Integer, TierConfig> tierMap = new Map<Integer, TierConfig>();

        List<Quantity_Tier__mdt> rawTiers = tierConfigOverride != null
            ? tierConfigOverride
            : [
                SELECT Quantity__c, Sort_Order__c, Is_Base_Tier__c
                FROM Quantity_Tier__mdt
                ORDER BY Sort_Order__c ASC
            ];

        for (Quantity_Tier__mdt tier : rawTiers) {
            TierConfig tc = new TierConfig();
            tc.quantity = tier.Quantity__c;
            tc.sortOrder = tier.Sort_Order__c;
            tc.isBaseTier = tier.Is_Base_Tier__c;
            tc.adjustmentType = null;
            tc.dollarAdjustment = null;
            tc.percentDiscount = null;
            tierMap.put(tier.Quantity__c.intValue(), tc);
        }

        List<Tier_Adjustment__mdt> rawAdjustments = tierAdjustmentOverride != null
            ? tierAdjustmentOverride
            : [
                SELECT Quantity__c, Adjustment_Type__c, Dollar_Adjustment__c, Percent_Discount__c
                FROM Tier_Adjustment__mdt
            ];

        for (Tier_Adjustment__mdt adj : rawAdjustments) {
            TierConfig tc = tierMap.get(adj.Quantity__c.intValue());
            if (tc != null) {
                tc.adjustmentType = adj.Adjustment_Type__c;
                tc.dollarAdjustment = adj.Dollar_Adjustment__c;
                tc.percentDiscount = adj.Percent_Discount__c;
            }
        }

        List<TierConfig> result = new List<TierConfig>(tierMap.values());
        result.sort();
        return result;
    }

    // --- Estimator wrapper classes ---

    public class EstimateItem {
        @AuraEnabled public String label;
        @AuraEnabled public Decimal price;
    }

    public class EstimateResult {
        @AuraEnabled public Decimal totalPrice;
        @AuraEnabled public List<EstimateItem> items;
    }

    // --- Estimator methods ---

    /**
     * Look up the Authenticated pricebook (case-insensitive contains match).
     * Used for estimator pricing and for Simple-product base-style lookups.
     */
    @AuraEnabled(cacheable=true)
    public static Id getAuthenticatedPricebookId() {
        List<Pricebook2> pbs = [
            SELECT Id FROM Pricebook2
            WHERE Name LIKE '%Authenticated%' AND IsActive = true
            LIMIT 1
        ];
        return pbs.isEmpty() ? null : pbs[0].Id;
    }

    /**
     * Find the estimator base product matching an opportunity product's CDN style ID.
     * Returns null if no match found.
     */
    @AuraEnabled(cacheable=true)
    public static Product2 getEstimatorProduct(String cdnStyleId) {
        if (String.isBlank(cdnStyleId)) {
            return null;
        }
        List<Product2> products = [
            SELECT Id, Name, ProductCode, Estimator_Decorations__c, Image_SAP__c
            FROM Product2
            WHERE ProductCode = :cdnStyleId AND Estimator__c = 'Product'
            LIMIT 1
        ];
        return products.isEmpty() ? null : products[0];
    }

    /**
     * Get available decoration products for an estimator product.
     * Reads Estimator_Decorations__c multiselect picklist (semicolon-delimited ProductCodes)
     * and returns matching Product2 records with their Estimator__c usage type.
     */
    @AuraEnabled(cacheable=true)
    public static List<Product2> getDecorationOptions(Id estimatorProductId) {
        if (estimatorProductId == null) {
            return new List<Product2>();
        }
        List<Product2> parentProducts = [
            SELECT Id, Estimator_Decorations__c
            FROM Product2
            WHERE Id = :estimatorProductId AND Estimator__c = 'Product'
        ];
        if (parentProducts.isEmpty() || String.isBlank(parentProducts[0].Estimator_Decorations__c)) {
            return new List<Product2>();
        }
        List<String> decorationProductCodes = parentProducts[0].Estimator_Decorations__c.split(';');
        List<String> decorationUsage = new List<String>{ 'Decoration', 'Decoration_Main', 'Decoration_Additional' };
        return [
            SELECT Id, Name, Estimator__c, ProductCode
            FROM Product2
            WHERE ProductCode IN :decorationProductCodes
              AND Estimator__c IN :decorationUsage
            ORDER BY Name ASC
        ];
    }

    /**
     * Calculate estimated unit price for a product + decoration combination.
     * Uses PricebookEntry on the Authenticated pricebook for base pricing, with
     * Product_Estimator_Decoration__c overrides for the main decoration when available.
     */
    @AuraEnabled
    public static EstimateResult getEstimatedPrice(Id estimatorProductId, Id mainDecorationId,
            List<String> additionalDecorationIds) {
        if (estimatorProductId == null || mainDecorationId == null) {
            throw new AuraHandledException('Missing required parameters for estimate calculation');
        }

        Id pricebookId = getAuthenticatedPricebookId();
        if (pricebookId == null) {
            throw new AuraHandledException('Authenticated pricebook not found');
        }

        EstimateResult result = new EstimateResult();
        result.totalPrice = 0;
        result.items = new List<EstimateItem>();

        // 1. Get base product price from PricebookEntry
        List<PricebookEntry> basePbe = [
            SELECT UnitPrice, Product2.Name
            FROM PricebookEntry
            WHERE Product2Id = :estimatorProductId AND Pricebook2Id = :pricebookId AND IsActive = true
            LIMIT 1
        ];
        if (basePbe.isEmpty()) {
            throw new AuraHandledException('No active pricebook entry found for the base product');
        }
        Decimal basePrice = basePbe[0].UnitPrice;
        result.totalPrice += basePrice;

        // 2. Check for main decoration override
        Decimal mainDecPrice;
        String mainDecName;
        List<Product_Estimator_Decoration__c> overrides = [
            SELECT Override_Price__c, Decoration__r.Name
            FROM Product_Estimator_Decoration__c
            WHERE Product__c = :estimatorProductId AND Decoration__c = :mainDecorationId
              AND Price_Book__c = :pricebookId
            LIMIT 1
        ];
        if (!overrides.isEmpty()) {
            mainDecPrice = overrides[0].Override_Price__c;
            mainDecName = overrides[0].Decoration__r.Name;
        } else {
            // Fallback to PricebookEntry
            List<PricebookEntry> decPbe = [
                SELECT UnitPrice, Product2.Name
                FROM PricebookEntry
                WHERE Product2Id = :mainDecorationId AND Pricebook2Id = :pricebookId AND IsActive = true
                LIMIT 1
            ];
            if (decPbe.isEmpty()) {
                throw new AuraHandledException('No active pricebook entry found for the main decoration');
            }
            mainDecPrice = decPbe[0].UnitPrice;
            mainDecName = decPbe[0].Product2.Name;
        }
        result.totalPrice += mainDecPrice;

        EstimateItem baseItem = new EstimateItem();
        baseItem.label = basePbe[0].Product2.Name + ' with ' + mainDecName;
        baseItem.price = basePrice + mainDecPrice;
        result.items.add(baseItem);

        // 3. Additional decorations (PricebookEntry only, no overrides)
        if (additionalDecorationIds != null && !additionalDecorationIds.isEmpty()) {
            Map<Id, PricebookEntry> addlPbeMap = new Map<Id, PricebookEntry>();
            for (PricebookEntry pbe : [
                SELECT Product2Id, UnitPrice, Product2.Name
                FROM PricebookEntry
                WHERE Product2Id IN :additionalDecorationIds
                  AND Pricebook2Id = :pricebookId AND IsActive = true
            ]) {
                addlPbeMap.put(pbe.Product2Id, pbe);
            }

            for (String decId : additionalDecorationIds) {
                PricebookEntry pbe = addlPbeMap.get(decId);
                if (pbe != null) {
                    result.totalPrice += pbe.UnitPrice;
                    EstimateItem addlItem = new EstimateItem();
                    addlItem.label = pbe.Product2.Name;
                    addlItem.price = pbe.UnitPrice;
                    result.items.add(addlItem);
                }
            }
        }

        return result;
    }

    /**
     * Estimated LDP per quantity tier for a base style with the chosen decorations,
     * using the manufacturer's charges and small-quantity upcharges. Returns
     * available = false with a message when cost data is missing; it does not throw
     * for missing data so the wizard can continue without a cost.
     *
     * Exposed here rather than on QuoteCostService so users need access to only
     * one Apex class.
     */
    @AuraEnabled
    public static QuoteCostService.CostResult getQuickTurnCosts(Id estimatorProductId, Id mainDecorationId,
            List<String> additionalDecorationIds, Id manufacturerId, List<Decimal> quantities) {
        try {
            // Quantities arrive from Lightning as decimals; convert before use.
            List<Integer> wholeQuantities = new List<Integer>();
            for (Decimal quantity : quantities == null ? new List<Decimal>() : quantities) {
                if (quantity != null) {
                    wholeQuantities.add(quantity.intValue());
                }
            }
            return QuoteCostService.calculate(estimatorProductId, mainDecorationId,
                additionalDecorationIds, manufacturerId, wholeQuantities);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'getQuickTurnCosts failed: ' + e.getMessage()
                + ' ' + e.getStackTraceString());
            QuoteCostService.CostResult failed = new QuoteCostService.CostResult();
            failed.message = 'LDP could not be estimated. Ask an administrator to check the cost data.';
            return failed;
        }
    }

    /**
     * Get all PriceAdjustmentTier values for a schedule matching the name pattern.
     * Returns a map of LowerBound → TierValue (dollar adjustments per tier).
     * Returns null if no matching schedule or input is blank.
     */
    @AuraEnabled(cacheable=true)
    public static Map<Decimal, Decimal> getScheduleAdjustments(String scheduleNameInput) {
        if (String.isBlank(scheduleNameInput)) {
            return null;
        }

        String searchPattern = '%' + scheduleNameInput + '%';
        List<PriceAdjustmentSchedule> schedules = [
            SELECT Id, Name
            FROM PriceAdjustmentSchedule
            WHERE Name LIKE :searchPattern AND Name LIKE '%net%'
            LIMIT 1
        ];

        if (schedules.isEmpty()) {
            return null;
        }

        List<PriceAdjustmentTier> tiers = [
            SELECT LowerBound, TierValue
            FROM PriceAdjustmentTier
            WHERE PriceAdjustmentScheduleId = :schedules[0].Id
            ORDER BY LowerBound ASC
        ];

        if (tiers.isEmpty()) {
            return null;
        }

        Map<Decimal, Decimal> result = new Map<Decimal, Decimal>();
        for (PriceAdjustmentTier tier : tiers) {
            result.put(tier.LowerBound, tier.TierValue);
        }
        return result;
    }

    // --- Base-style pricing pipeline (shared by Simple and Quick products) ---

    public class BaseStylePricing {
        @AuraEnabled public Decimal moqPrice;
        @AuraEnabled public Decimal anchorQuantity;
        @AuraEnabled public Map<Decimal, Decimal> scheduleAdjustments;
    }

    /**
     * Resolve the tier-pricing inputs anchored on a base-style Product2.
     *   1. Base style Product2 matched by CDN_Style_ID_SAP__c → ProductCode
     *   2. Authenticated pricebook (shared lookup)
     *   3. PricebookEntry on Authenticated pricebook → MOQ price (optional)
     *   4. ProductQuantityRule → PurchaseQuantityRule.Minimum → anchor tier (optional)
     *   5. PricebookEntryAdjustment junction → PriceAdjustmentSchedule
     *   6. PriceAdjustmentTier rows → Map<quantity, dollarAdjustment>
     *
     * Simple products use moqPrice + anchorQuantity + scheduleAdjustments.
     * Quick products only use scheduleAdjustments (the estimator supplies the
     * anchor price at tier 144). Returns null only when the base style or
     * Authenticated pricebook can't be found; otherwise individual fields may
     * be null and the caller decides how to handle partial data.
     */
    @AuraEnabled(cacheable=true)
    public static BaseStylePricing getBaseStylePricing(String cdnStyleId) {
        if (String.isBlank(cdnStyleId)) {
            return null;
        }

        List<Product2> bases = [
            SELECT Id FROM Product2 WHERE ProductCode = :cdnStyleId LIMIT 1
        ];
        if (bases.isEmpty()) {
            return null;
        }
        Id baseId = bases[0].Id;

        Id authPbId = getAuthenticatedPricebookId();
        if (authPbId == null) {
            return null;
        }

        BaseStylePricing result = new BaseStylePricing();
        result.scheduleAdjustments = new Map<Decimal, Decimal>();

        // PurchaseQuantityRule.Minimum → anchor (only needed by Simple products).
        List<ProductQuantityRule> rules = [
            SELECT PurchaseQuantityRule.Minimum
            FROM ProductQuantityRule
            WHERE ProductId = :baseId
              AND PurchaseQuantityRule.Minimum != null
            ORDER BY PurchaseQuantityRule.Minimum ASC
            LIMIT 1
        ];
        if (!rules.isEmpty()
                && rules[0].PurchaseQuantityRule != null
                && rules[0].PurchaseQuantityRule.Minimum != null) {
            result.anchorQuantity = rules[0].PurchaseQuantityRule.Minimum;
        }

        // Authenticated PBE → MOQ price + junction lookup.
        List<PricebookEntry> pbes = [
            SELECT Id, UnitPrice FROM PricebookEntry
            WHERE Product2Id = :baseId
              AND Pricebook2Id = :authPbId
              AND IsActive = true
            LIMIT 1
        ];
        if (pbes.isEmpty()) {
            return result;
        }
        result.moqPrice = pbes[0].UnitPrice;

        List<PricebookEntryAdjustment> junctions = [
            SELECT PriceAdjustmentScheduleId
            FROM PricebookEntryAdjustment
            WHERE PricebookEntryId = :pbes[0].Id
            LIMIT 1
        ];
        if (!junctions.isEmpty() && junctions[0].PriceAdjustmentScheduleId != null) {
            for (PriceAdjustmentTier t : [
                SELECT LowerBound, TierValue FROM PriceAdjustmentTier
                WHERE PriceAdjustmentScheduleId = :junctions[0].PriceAdjustmentScheduleId
                ORDER BY LowerBound ASC
            ]) {
                if (t.LowerBound != null) {
                    result.scheduleAdjustments.put(t.LowerBound, t.TierValue);
                }
            }
        }
        System.debug(LoggingLevel.INFO, 'getBaseStylePricing cdnStyleId=' + cdnStyleId
            + ' baseId=' + baseId
            + ' authPbId=' + authPbId
            + ' moqPrice=' + result.moqPrice
            + ' anchorQuantity=' + result.anchorQuantity
            + ' scheduleAdjustments=' + result.scheduleAdjustments);
        return result;
    }

    /**
     * Get the Pricebook2Id for an Opportunity.
     */
    @AuraEnabled(cacheable=true)
    public static Id getOpportunityPricebookId(String opportunityId) {
        if (String.isBlank(opportunityId)) {
            return null;
        }
        List<Opportunity> opps = [SELECT Pricebook2Id FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
        return opps.isEmpty() ? null : opps[0].Pricebook2Id;
    }

    /**
     * Fetch the name + tier air rates for a mfg__c record. Used by the pricing
     * card when a user overrides the manufacturer on a VariationParent card — we
     * re-derive Air prices from the new rates without touching Ocean prices.
     */
    public class ManufacturerAirRates {
        @AuraEnabled public Id manufacturerId;
        @AuraEnabled public String name;
        @AuraEnabled public String coo;
        @AuraEnabled public Decimal x144;
        @AuraEnabled public Decimal x288;
        @AuraEnabled public Decimal x576;
        @AuraEnabled public Decimal x1008;
    }

    @AuraEnabled(cacheable=true)
    public static ManufacturerAirRates getManufacturerAirRates(Id manufacturerId) {
        if (manufacturerId == null) {
            return null;
        }
        List<mfg__c> rows = [
            SELECT Id, Name, COO__c,
                   X144_Air_Rate__c, X288_Air_Rate__c,
                   X576_Air_Rate__c, X1008_Air_Rate__c
            FROM mfg__c
            WHERE Id = :manufacturerId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return null;
        }
        ManufacturerAirRates r = new ManufacturerAirRates();
        r.manufacturerId = rows[0].Id;
        r.name = rows[0].Name;
        r.coo = rows[0].COO__c;
        r.x144 = rows[0].X144_Air_Rate__c;
        r.x288 = rows[0].X288_Air_Rate__c;
        r.x576 = rows[0].X576_Air_Rate__c;
        r.x1008 = rows[0].X1008_Air_Rate__c;
        return r;
    }

    // Map of tier quantity to the Ocean and Air field API names on QuoteLineItem
    private static final Map<Integer, String> TIER_OCEAN_FIELDS = new Map<Integer, String>{
        72 => 'X72_Ocean_Currency__c',
        144 => 'X144_Ocean_Currency__c',
        288 => 'X288_Ocean_Currency__c',
        576 => 'X576_Ocean_Currency__c',
        1008 => 'X1008_Ocean_Currency__c',
        2592 => 'X2592_Ocean_Currency__c',
        5040 => 'X5040_Ocean_Currency__c',
        10080 => 'X10080_Ocean_Currency__c',
        20016 => 'X20016_Ocean_Currency__c',
        50112 => 'X50112_Ocean_Currency__c'
    };

    private static final Map<Integer, String> TIER_AIR_FIELDS = new Map<Integer, String>{
        144 => 'X144_Air_Currency__c',
        288 => 'X288_Air_Currency__c',
        576 => 'X576_Air_Currency__c',
        1008 => 'X1008_Air_Currency__c'
    };

    @AuraEnabled
    public static String createQuoteWithLineItems(String quoteDataJson) {
        QuoteRequest request = (QuoteRequest) JSON.deserialize(quoteDataJson, QuoteRequest.class);

        Opportunity opp = [
            SELECT Id, Name, Pricebook2Id, AccountId, Contact__c, Contact__r.Email
            FROM Opportunity
            WHERE Id = :request.opportunityId
            LIMIT 1
        ];

        Quote newQuote = new Quote();
        newQuote.Name = opp.Name + ' - Quote';
        newQuote.OpportunityId = opp.Id;
        newQuote.Pricebook2Id = opp.Pricebook2Id;
        if (opp.Contact__c != null) {
            newQuote.ContactId = opp.Contact__c;
            if (opp.Contact__r.Email != null) {
                newQuote.Email = opp.Contact__r.Email;
            }
        }
        newQuote.ExpirationDate = String.isNotBlank(request.expirationDate)
            ? Date.valueOf(request.expirationDate)
            : Date.today().addDays(14);
        if (request.minQuantity != null) {
            newQuote.Min_Quantity_Tier__c = request.minQuantity;
        }
        if (request.maxQuantity != null) {
            newQuote.Max_Quantity_Tier__c = request.maxQuantity;
        }
        insert newQuote;

        // Collect all product IDs to bulk-query PricebookEntries
        Set<String> productIds = new Set<String>();
        for (QuoteLineItemData item : request.lineItems) {
            productIds.add(item.productId);
        }

        // Keyed by the 18-character Id string the client sends.
        Map<String, Product2> quotedProducts = new Map<String, Product2>();
        for (Product2 p : [
            SELECT Id, ProductCode, Special_Program_SAP__c, Description
            FROM Product2
            WHERE Id IN :productIds
        ]) {
            quotedProducts.put(String.valueOf(p.Id), p);
        }

        Map<String, Id> productToPbeId = new Map<String, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Product2Id IN :productIds
              AND Pricebook2Id = :opp.Pricebook2Id
              AND IsActive = true
        ]) {
            productToPbeId.put(pbe.Product2Id, pbe.Id);
        }

        List<QuoteLineItem> qlis = new List<QuoteLineItem>();
        for (QuoteLineItemData item : request.lineItems) {
            Id pbeId = productToPbeId.get(item.productId);
            if (pbeId == null) {
                continue;
            }

            // One QuoteLineItem per product with tier prices as columns
            QuoteLineItem qli = new QuoteLineItem();
            qli.QuoteId = newQuote.Id;
            qli.PricebookEntryId = pbeId;
            qli.Quantity = 1;
            qli.UnitPrice = item.ldp != null ? item.ldp : 0;

            if (String.isNotBlank(item.oceanLeadtime)) {
                qli.Ocean_Leadtime__c = item.oceanLeadtime;
            }
            if (String.isNotBlank(item.airLeadTime)) {
                qli.Air_Lead_Time__c = item.airLeadTime;
            }
            if (String.isNotBlank(item.coo)) {
                qli.COO_Override__c = item.coo;
            }
            if (String.isNotBlank(item.customDescription)) {
                qli.Custom_Description__c = item.customDescription;
            }

            // Quick Turn and North American Custom lines never carry air pricing,
            // whatever the client sent.
            Product2 quoted = quotedProducts.get(item.productId);
            Boolean allowAir = quoted == null
                || !(QuoteCostService.isQuickProgram(quoted.Special_Program_SAP__c)
                     || QuoteCostService.isNorthAmericanCustom(quoted.ProductCode));

            String snapshot = buildCostSnapshot(item);
            if (snapshot != null) {
                qli.Cost_Snapshot__c = snapshot;
            }

            // Set tier prices from the map (keys like "1008_Ocean", "1008_Air")
            if (item.tierPrices != null) {
                for (String key : item.tierPrices.keySet()) {
                    Decimal price = item.tierPrices.get(key);
                    String[] parts = key.split('_');
                    if (parts.size() >= 2) {
                        if (!parts[0].isNumeric()) {
                            continue;
                        }
                        Integer qty = Integer.valueOf(parts[0]);
                        String shippingType = parts[1];
                        if (shippingType == 'Air' && !allowAir) {
                            continue;
                        }

                        String fieldName;
                        if (shippingType == 'Ocean') {
                            fieldName = TIER_OCEAN_FIELDS.get(qty);
                        } else if (shippingType == 'Air') {
                            fieldName = TIER_AIR_FIELDS.get(qty);
                        }

                        if (fieldName != null && price != null) {
                            qli.put(fieldName, price);
                        }
                    }
                }
            }

            qlis.add(qli);
        }

        if (!qlis.isEmpty()) {
            insert qlis;
        }

        saveQuoteDescriptions(request.lineItems, quotedProducts);

        // Generate PDF asynchronously to avoid DML-before-callout restriction
        generateQuotePDFAsync(newQuote.Id);

        return newQuote.Id;
    }

    /**
     * JSON snapshot of LDP, sell price and margin per tier for one line:
     * {"144":{"ldp":5.1234,"price":12.75,"marginPct":59.82}}. Returns null when the
     * client sent no LDPs. Stored for audit; never read by the quote PDF.
     */
    @TestVisible
    private static String buildCostSnapshot(QuoteLineItemData item) {
        if (item.tierLdps == null || item.tierLdps.isEmpty()) {
            return null;
        }
        Map<String, Object> snapshot = new Map<String, Object>();
        for (String qtyKey : item.tierLdps.keySet()) {
            Decimal ldp = item.tierLdps.get(qtyKey);
            if (ldp == null || !qtyKey.isNumeric()) {
                continue;
            }
            Map<String, Object> tier = new Map<String, Object>{ 'ldp' => ldp };
            Decimal price = item.tierPrices == null ? null : item.tierPrices.get(qtyKey + '_Ocean');
            if (price != null && price > 0) {
                tier.put('price', price);
                tier.put('marginPct', ((1 - ldp / price) * 100).setScale(2, RoundingMode.HALF_UP));
            }
            snapshot.put(qtyKey, tier);
        }
        if (snapshot.isEmpty()) {
            return null;
        }
        String serialized = JSON.serialize(snapshot);
        return serialized.length() > 10000 ? null : serialized;
    }

    /**
     * Save each line's custom description to Product2.Description (Text Area, 4000) so
     * the next quote for the style starts with it. This replaces the product's existing
     * description. A failure here is logged and does not fail
     * the quote, which is already inserted.
     */
    private static final Integer PRODUCT_DESCRIPTION_MAX = 4000;

    private static void saveQuoteDescriptions(List<QuoteLineItemData> items, Map<String, Product2> quotedProducts) {
        Map<Id, Product2> updates = new Map<Id, Product2>();
        for (QuoteLineItemData item : items) {
            if (String.isBlank(item.customDescription) || String.isBlank(item.productId)) {
                continue;
            }
            Product2 existing = quotedProducts.get(item.productId);
            String description = item.customDescription.trim().left(PRODUCT_DESCRIPTION_MAX);
            if (existing == null || existing.Description == description) {
                continue;
            }
            updates.put(existing.Id, new Product2(Id = existing.Id, Description = description));
        }
        if (updates.isEmpty()) {
            return;
        }
        for (Database.SaveResult sr : Database.update(updates.values(), false)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Quote description not saved for Product2 '
                    + sr.getId() + ': ' + sr.getErrors());
            }
        }
    }

    // Synchronous PDF fetch for immediate client-side download after quote creation.
    // Runs in a separate transaction from createQuoteWithLineItems, so there is no
    // DML-before-callout restriction here — the @future attach path remains unchanged.
    @AuraEnabled
    public static String getQuotePdfBase64(Id quoteId) {
        PageReference pdfPage = new PageReference('/apex/CDN_Quote_Page');
        pdfPage.getParameters().put('id', String.valueOf(quoteId));

        Blob pdfBlob;
        if (!Test.isRunningTest()) {
            pdfBlob = pdfPage.getContentAsPDF();
        } else {
            pdfBlob = Blob.valueOf('Test PDF');
        }
        return EncodingUtil.base64Encode(pdfBlob);
    }

    @AuraEnabled
    public static void regenerateQuotePdf(Id quoteId) {
        PageReference pdfPage = new PageReference('/apex/CDN_Quote_Page');
        pdfPage.getParameters().put('id', String.valueOf(quoteId));

        Blob pdfBlob;
        if (!Test.isRunningTest()) {
            pdfBlob = pdfPage.getContentAsPDF();
        } else {
            pdfBlob = Blob.valueOf('Test PDF');
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Quote_' + quoteId + '.pdf';
        cv.PathOnClient = 'Quote_' + quoteId + '.pdf';
        cv.VersionData = pdfBlob;
        cv.IsMajorVersion = true;
        cv.Origin = 'H';
        insert cv;

        ContentDocument doc = [SELECT Id FROM ContentDocument WHERE LatestPublishedVersionId = :cv.Id LIMIT 1];

        ContentDocumentLink link = new ContentDocumentLink();
        link.ContentDocumentId = doc.Id;
        link.LinkedEntityId = quoteId;
        link.ShareType = 'V';
        insert link;
    }

    @future(callout=true)
    public static void generateQuotePDFAsync(Id quoteId) {
        try {
            PageReference pdfPage = new PageReference('/apex/CDN_Quote_Page');
            pdfPage.getParameters().put('id', String.valueOf(quoteId));

            Blob pdfBlob;
            if (!Test.isRunningTest()) {
                pdfBlob = pdfPage.getContentAsPDF();
            } else {
                pdfBlob = Blob.valueOf('Test PDF');
            }

            ContentVersion cv = new ContentVersion();
            cv.Title = 'Quote_' + quoteId + '.pdf';
            cv.PathOnClient = 'Quote_' + quoteId + '.pdf';
            cv.VersionData = pdfBlob;
            cv.IsMajorVersion = true;
            cv.Origin = 'H';
            insert cv;

            ContentDocument doc = [SELECT Id FROM ContentDocument WHERE LatestPublishedVersionId = :cv.Id LIMIT 1];

            ContentDocumentLink link = new ContentDocumentLink();
            link.ContentDocumentId = doc.Id;
            link.LinkedEntityId = quoteId;
            link.ShareType = 'V';
            insert link;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PDF generation failed for Quote ' + quoteId + ': ' + e.getMessage());
        }
    }
}
