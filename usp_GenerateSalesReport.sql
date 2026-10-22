
CREATE OR ALTER PROCEDURE dbo.usp_GenerateSalesReport
(
    @StartDate DATE,
    @EndDate DATE,
    @CategoryID INT = NULL,
    @RegionID INT = NULL,
    @MinSalesAmount DECIMAL(18,2) = 0,
    @MaxDiscountPercent DECIMAL(5,2) = 100,
    @TopCustomerCount INT = 10,
    @IncludeShippedOrders BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Step 1: Declare variables
    DECLARE @TotalOrders INT = 0;
    DECLARE @TotalRevenue DECIMAL(18,2) = 0;
    DECLARE @TotalCustomers INT = 0;
    DECLARE @TotalUnits BIGINT = 0;
    DECLARE @TotalCost DECIMAL(18,2) = 0;
    DECLARE @TotalProfit DECIMAL(18,2) = 0;
    DECLARE @ExecutionTime DATETIME2 = SYSDATETIME();

    -- Step 2: Validate input parameters
    IF @StartDate IS NULL OR @EndDate IS NULL
        THROW 50001, 'Start and end dates are required.', 1;

    IF @StartDate > @EndDate
        THROW 50002, 'Start date must precede end date.', 1;

    IF DATEDIFF(DAY, @StartDate, @EndDate) > 366
        THROW 50003, 'Reporting period cannot exceed 366 days.', 1;

    IF @MinSalesAmount < 0
        THROW 50004, 'Minimum sales cannot be negative.', 1;

    IF @MaxDiscountPercent < 0 OR @MaxDiscountPercent > 100
        THROW 50005, 'Discount percentage must be between 0 and 100.', 1;

    IF @TopCustomerCount < 1 OR @TopCustomerCount > 100
        THROW 50006, 'Top customer count must be between 1 and 100.', 1;

    BEGIN TRY

        -- Step 3: Prepare temporary sales table
        DROP TABLE IF EXISTS #SalesData;
        DROP TABLE IF EXISTS #MonthlySummary;

        CREATE TABLE #SalesData
        (
            OrderID INT NOT NULL,
            CustomerID INT NOT NULL,
            ProductID INT NOT NULL,
            ProductName NVARCHAR(200),
            CategoryID INT,
            RegionID INT,
            OrderDate DATE,
            Quantity INT,
            UnitPrice DECIMAL(18,2),
            DiscountPercent DECIMAL(5,2),
            GrossAmount DECIMAL(18,2),
            NetAmount DECIMAL(18,2),
            EstimatedCost DECIMAL(18,2),
            EstimatedProfit DECIMAL(18,2)
        );

        -- Step 4: Load sales data with enhanced calculations
        INSERT INTO #SalesData
        (
            OrderID, CustomerID, ProductID, ProductName,
            CategoryID, RegionID, OrderDate, Quantity,
            UnitPrice, DiscountPercent, GrossAmount,
            NetAmount, EstimatedCost, EstimatedProfit
        )
        SELECT
            O.OrderID,
            O.CustomerID,
            P.ProductID,
            P.ProductName,
            P.CategoryID,
            O.RegionID,
            CAST(O.OrderDate AS DATE),
            OD.Quantity,
            OD.UnitPrice,
            COALESCE(OD.DiscountPercent, 0),
            OD.Quantity * OD.UnitPrice,
            OD.Quantity * OD.UnitPrice
                * (1 - COALESCE(OD.DiscountPercent, 0) / 100.0),
            OD.Quantity * COALESCE(P.UnitCost, 0),
            OD.Quantity * OD.UnitPrice
                * (1 - COALESCE(OD.DiscountPercent, 0) / 100.0)
                - OD.Quantity * COALESCE(P.UnitCost, 0)
        FROM dbo.Orders AS O
        INNER JOIN dbo.OrderDetails AS OD
            ON O.OrderID = OD.OrderID
        INNER JOIN dbo.Products AS P
            ON OD.ProductID = P.ProductID
        WHERE O.OrderDate >= @StartDate
          AND O.OrderDate < DATEADD(DAY, 1, @EndDate)
          AND (
                O.Status = 'Completed'
                OR (@IncludeShippedOrders = 1
                    AND O.Status = 'Shipped')
              )
          AND (@CategoryID IS NULL
               OR P.CategoryID = @CategoryID)
          AND (@RegionID IS NULL
               OR O.RegionID = @RegionID)
          AND COALESCE(OD.DiscountPercent, 0)
              <= @MaxDiscountPercent;

        -- Step 5: Create indexes for reporting queries
        CREATE CLUSTERED INDEX IX_SalesData_Order
            ON #SalesData (OrderID, ProductID);

        CREATE NONCLUSTERED INDEX IX_SalesData_Customer
            ON #SalesData (CustomerID, OrderDate);

        -- Step 6: Calculate overall metrics
        SELECT
            @TotalOrders = COUNT(DISTINCT OrderID),
            @TotalCustomers = COUNT(DISTINCT CustomerID),
            @TotalUnits = COALESCE(SUM(Quantity), 0),
            @TotalRevenue = COALESCE(SUM(NetAmount), 0),
            @TotalCost = COALESCE(SUM(EstimatedCost), 0),
            @TotalProfit = COALESCE(SUM(EstimatedProfit), 0)
        FROM #SalesData;

        -- Step 7: Return enhanced overall summary
        SELECT
            @StartDate AS StartDate,
            @EndDate AS EndDate,
            @TotalOrders AS TotalOrders,
            @TotalCustomers AS TotalCustomers,
            @TotalUnits AS TotalUnitsSold,
            @TotalRevenue AS TotalRevenue,
            @TotalCost AS EstimatedCost,
            @TotalProfit AS EstimatedProfit,
            CASE
                WHEN @TotalOrders > 0
                    THEN @TotalRevenue / @TotalOrders
                ELSE 0
            END AS AverageOrderValue,
            CAST(
                100.0 * @TotalProfit / NULLIF(@TotalRevenue, 0)
                AS DECIMAL(8,2)
            ) AS ProfitMarginPercent,
            @ExecutionTime AS ReportGeneratedAt;

        -- Step 8: Return product performance and profitability
        SELECT
            ProductID,
            ProductName,
            CategoryID,
            SUM(Quantity) AS UnitsSold,
            COUNT(DISTINCT OrderID) AS OrderCount,
            SUM(GrossAmount) AS GrossSales,
            SUM(NetAmount) AS NetSales,
            SUM(EstimatedCost) AS EstimatedCost,
            SUM(EstimatedProfit) AS EstimatedProfit,
            CAST(
                100.0 * SUM(EstimatedProfit)
                / NULLIF(SUM(NetAmount), 0)
                AS DECIMAL(8,2)
            ) AS ProfitMarginPercent,
            CAST(
                100.0 * SUM(NetAmount)
                / NULLIF(@TotalRevenue, 0)
                AS DECIMAL(8,2)
            ) AS RevenueContributionPercent
        FROM #SalesData
        GROUP BY ProductID, ProductName, CategoryID
        HAVING SUM(NetAmount) >= @MinSalesAmount
        ORDER BY NetSales DESC;

        -- Step 9: Rank and segment customers
        SELECT TOP (@TopCustomerCount)
            S.CustomerID,
            C.CustomerName,
            COUNT(DISTINCT S.OrderID) AS OrderCount,
            SUM(S.NetAmount) AS TotalSpent,
            MAX(S.OrderDate) AS LastOrderDate,
            DENSE_RANK() OVER (
                ORDER BY SUM(S.NetAmount) DESC
            ) AS CustomerRank,
            CASE
                WHEN SUM(S.NetAmount) >= 10000 THEN 'Platinum'
                WHEN SUM(S.NetAmount) >= 5000 THEN 'Gold'
                WHEN SUM(S.NetAmount) >= 1000 THEN 'Silver'
                ELSE 'Standard'
            END AS CustomerSegment
        FROM #SalesData AS S
        INNER JOIN dbo.Customers AS C
            ON S.CustomerID = C.CustomerID
        GROUP BY S.CustomerID, C.CustomerName
        ORDER BY TotalSpent DESC;

        -- Step 10: Build monthly revenue summary
        CREATE TABLE #MonthlySummary
        (
            SalesYear INT,
            SalesMonth INT,
            OrderCount INT,
            MonthlyRevenue DECIMAL(18,2)
        );

        INSERT INTO #MonthlySummary
        SELECT
            YEAR(OrderDate),
            MONTH(OrderDate),
            COUNT(DISTINCT OrderID),
            SUM(NetAmount)
        FROM #SalesData
        GROUP BY YEAR(OrderDate), MONTH(OrderDate);

        -- Step 11: Compare monthly revenue with previous month
        SELECT
            SalesYear,
            SalesMonth,
            OrderCount,
            MonthlyRevenue,
            LAG(MonthlyRevenue) OVER (
                ORDER BY SalesYear, SalesMonth
            ) AS PreviousMonthRevenue,
            MonthlyRevenue
                - LAG(MonthlyRevenue) OVER (
                    ORDER BY SalesYear, SalesMonth
                ) AS RevenueChange,
            CAST(
                100.0 * (
                    MonthlyRevenue
                    - LAG(MonthlyRevenue) OVER (
                        ORDER BY SalesYear, SalesMonth
                    )
                )
                / NULLIF(
                    LAG(MonthlyRevenue) OVER (
                        ORDER BY SalesYear, SalesMonth
                    ), 0
                )
                AS DECIMAL(8,2)
            ) AS RevenueGrowthPercent
        FROM #MonthlySummary
        ORDER BY SalesYear, SalesMonth;

        -- Step 12: Return regional performance
        SELECT
            RegionID,
            COUNT(DISTINCT OrderID) AS OrderCount,
            COUNT(DISTINCT CustomerID) AS CustomerCount,
            SUM(Quantity) AS UnitsSold,
            SUM(NetAmount) AS RegionalRevenue,
            SUM(EstimatedProfit) AS RegionalProfit,
            DENSE_RANK() OVER (
                ORDER BY SUM(NetAmount) DESC
            ) AS RevenueRank
        FROM #SalesData
        GROUP BY RegionID
        ORDER BY RegionalRevenue DESC;

        -- Step 13: Return category-level performance
        SELECT
            CategoryID,
            COUNT(DISTINCT ProductID) AS ProductsSold,
            SUM(Quantity) AS UnitsSold,
            SUM(NetAmount) AS CategoryRevenue,
            SUM(EstimatedProfit) AS CategoryProfit,
            CAST(
                100.0 * SUM(NetAmount)
                / NULLIF(@TotalRevenue, 0)
                AS DECIMAL(8,2)
            ) AS RevenueSharePercent
        FROM #SalesData
        GROUP BY CategoryID
        ORDER BY CategoryRevenue DESC;

        -- Step 14: Analyze discount effectiveness
        SELECT
            CASE
                WHEN DiscountPercent = 0 THEN 'No Discount'
                WHEN DiscountPercent <= 10 THEN 'Low Discount'
                WHEN DiscountPercent <= 20 THEN 'Medium Discount'
                ELSE 'High Discount'
            END AS DiscountCategory,
            COUNT(*) AS SalesLines,
            SUM(GrossAmount) AS GrossRevenue,
            SUM(NetAmount) AS NetRevenue,
            SUM(EstimatedProfit) AS EstimatedProfit
        FROM #SalesData
        GROUP BY
            CASE
                WHEN DiscountPercent = 0 THEN 'No Discount'
                WHEN DiscountPercent <= 10 THEN 'Low Discount'
                WHEN DiscountPercent <= 20 THEN 'Medium Discount'
                ELSE 'High Discount'
            END
        ORDER BY NetRevenue DESC;

        -- Step 15: Identify unusually large orders
        SELECT
            OrderID,
            COUNT(DISTINCT ProductID) AS ProductCount,
            SUM(Quantity) AS TotalUnits,
            SUM(NetAmount) AS OrderValue,
            CASE
                WHEN SUM(NetAmount) >= 10000 THEN 'Large'
                WHEN SUM(NetAmount) >= 5000 THEN 'Medium'
                ELSE 'Regular'
            END AS OrderCategory
        FROM #SalesData
        GROUP BY OrderID
        HAVING SUM(NetAmount) >= 1000
        ORDER BY OrderValue DESC;

        -- Step 16: Return data quality metrics
        SELECT
            COUNT(*) AS TotalLines,
            SUM(CASE WHEN Quantity <= 0 THEN 1 ELSE 0 END)
                AS InvalidQuantityLines,
            SUM(CASE WHEN UnitPrice < 0 THEN 1 ELSE 0 END)
                AS InvalidPriceLines,
            SUM(CASE WHEN DiscountPercent < 0
                       OR DiscountPercent > 100
                     THEN 1 ELSE 0 END) AS InvalidDiscountLines,
            SUM(CASE WHEN NetAmount < 0 THEN 1 ELSE 0 END)
                AS NegativeAmountLines
        FROM #SalesData;

        -- Step 17: Return report execution information
        SELECT
            DB_NAME() AS DatabaseName,
            OBJECT_SCHEMA_NAME(@@PROCID) AS ProcedureSchema,
            OBJECT_NAME(@@PROCID) AS ProcedureName,
            @ExecutionTime AS ExecutionStartedAt,
            SYSDATETIME() AS ExecutionFinishedAt,
            DATEDIFF(
                MILLISECOND, @ExecutionTime, SYSDATETIME()
            ) AS ElapsedMilliseconds;

        -- Step 18: Clean up temporary tables
        DROP TABLE IF EXISTS #MonthlySummary;
        DROP TABLE IF EXISTS #SalesData;

    END TRY
    BEGIN CATCH
        DROP TABLE IF EXISTS #MonthlySummary;
        DROP TABLE IF EXISTS #SalesData;
        THROW;
    END CATCH;
END;
GO
