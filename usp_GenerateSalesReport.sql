
CREATE OR ALTER PROCEDURE dbo.usp_GenerateSalesReport
(
    @StartDate DATE,
    @EndDate DATE,
    @CategoryID INT = NULL,
    @RegionID INT = NULL,
    @MinSalesAmount DECIMAL(18,2) = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Step 1: Declare variables
    DECLARE @TotalOrders INT = 0;
    DECLARE @TotalRevenue DECIMAL(18,2) = 0;
    DECLARE @TotalCustomers INT = 0;
    DECLARE @ExecutionTime DATETIME2 = SYSDATETIME();

    -- Step 2: Validate parameters
    IF @StartDate IS NULL OR @EndDate IS NULL
        THROW 50001, 'Start and end dates are required.', 1;

    IF @StartDate > @EndDate
        THROW 50002, 'Start date must precede end date.', 1;

    IF @MinSalesAmount < 0
        THROW 50003, 'Minimum sales cannot be negative.', 1;

    BEGIN TRY
        -- Step 3: Prepare temporary sales table
        DROP TABLE IF EXISTS #SalesData;

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
            NetAmount DECIMAL(18,2)
        );

        -- Step 4: Load filtered sales data
        INSERT INTO #SalesData
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
            OD.Quantity * OD.UnitPrice
                * (1 - COALESCE(OD.DiscountPercent, 0) / 100.0)
        FROM dbo.Orders O
        INNER JOIN dbo.OrderDetails OD
            ON O.OrderID = OD.OrderID
        INNER JOIN dbo.Products P
            ON OD.ProductID = P.ProductID
        WHERE O.OrderDate >= @StartDate
          AND O.OrderDate < DATEADD(DAY, 1, @EndDate)
          AND O.Status = 'Completed'
          AND (@CategoryID IS NULL
               OR P.CategoryID = @CategoryID)
          AND (@RegionID IS NULL
               OR O.RegionID = @RegionID);

        -- Step 5: Add an index for aggregation
        CREATE CLUSTERED INDEX IX_SalesData_Order
            ON #SalesData (OrderID, ProductID);

        -- Step 6: Calculate summary metrics
        SELECT
            @TotalOrders = COUNT(DISTINCT OrderID),
            @TotalCustomers = COUNT(DISTINCT CustomerID),
            @TotalRevenue = COALESCE(SUM(NetAmount), 0)
        FROM #SalesData;

        -- Step 7: Return overall summary
        SELECT
            @StartDate AS StartDate,
            @EndDate AS EndDate,
            @TotalOrders AS TotalOrders,
            @TotalCustomers AS TotalCustomers,
            @TotalRevenue AS TotalRevenue,
            CASE
                WHEN @TotalOrders > 0
                    THEN @TotalRevenue / @TotalOrders
                ELSE 0
            END AS AverageOrderValue,
            @ExecutionTime AS ReportGeneratedAt;

        -- Step 8: Return product performance
        SELECT
            ProductID,
            ProductName,
            CategoryID,
            SUM(Quantity) AS UnitsSold,
            COUNT(DISTINCT OrderID) AS OrderCount,
            SUM(NetAmount) AS SalesAmount,
            AVG(UnitPrice) AS AverageUnitPrice
        FROM #SalesData
        GROUP BY ProductID, ProductName, CategoryID
        HAVING SUM(NetAmount) >= @MinSalesAmount
        ORDER BY SalesAmount DESC;

        -- Step 9: Return customer performance
        SELECT TOP (10)
            S.CustomerID,
            C.CustomerName,
            COUNT(DISTINCT S.OrderID) AS OrderCount,
            SUM(S.NetAmount) AS TotalSpent,
            MAX(S.OrderDate) AS LastOrderDate,
            DENSE_RANK() OVER (
                ORDER BY SUM(S.NetAmount) DESC
            ) AS CustomerRank
        FROM #SalesData S
        INNER JOIN dbo.Customers C
            ON S.CustomerID = C.CustomerID
        GROUP BY S.CustomerID, C.CustomerName
        ORDER BY TotalSpent DESC;

        -- Step 10: Return monthly trends
        SELECT
            YEAR(OrderDate) AS SalesYear,
            MONTH(OrderDate) AS SalesMonth,
            COUNT(DISTINCT OrderID) AS OrderCount,
            SUM(NetAmount) AS MonthlyRevenue
        FROM #SalesData
        GROUP BY YEAR(OrderDate), MONTH(OrderDate)
        ORDER BY SalesYear, SalesMonth;

        -- Step 11: Return regional performance
        SELECT
            RegionID,
            COUNT(DISTINCT OrderID) AS OrderCount,
            COUNT(DISTINCT CustomerID) AS CustomerCount,
            SUM(NetAmount) AS RegionalRevenue
        FROM #SalesData
        GROUP BY RegionID
        ORDER BY RegionalRevenue DESC;

        -- Step 12: Return discount analysis
        SELECT
            CASE
                WHEN DiscountPercent = 0 THEN 'No Discount'
                WHEN DiscountPercent <= 10 THEN 'Low Discount'
                ELSE 'High Discount'
            END AS DiscountCategory,
            COUNT(*) AS SalesLines,
            SUM(NetAmount) AS NetRevenue
        FROM #SalesData
        GROUP BY
            CASE
                WHEN DiscountPercent = 0 THEN 'No Discount'
                WHEN DiscountPercent <= 10 THEN 'Low Discount'
                ELSE 'High Discount'
            END
        ORDER BY NetRevenue DESC;

        -- Step 13: Return data quality metrics
        SELECT
            COUNT(*) AS TotalLines,
            SUM(CASE WHEN Quantity <= 0 THEN 1 ELSE 0 END)
                AS InvalidQuantityLines,
            SUM(CASE WHEN UnitPrice < 0 THEN 1 ELSE 0 END)
                AS InvalidPriceLines,
            SUM(CASE WHEN NetAmount < 0 THEN 1 ELSE 0 END)
                AS NegativeAmountLines
        FROM #SalesData;

        -- Step 14: Clean up
        DROP TABLE IF EXISTS #SalesData;

    END TRY
    BEGIN CATCH
        DROP TABLE IF EXISTS #SalesData;
        THROW;
    END CATCH;
END;
GO
