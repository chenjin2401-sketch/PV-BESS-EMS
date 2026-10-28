%% prepare_day_ahead_price_data.m
% Prepare a 91-day Shandong day-ahead price dataset for the PV-BESS EMS.
%
% Working assumptions:
% 1. Market: Shandong, China.
% 2. Currency and unit: RMB/MWh.
% 3. A commercial user can purchase imported energy at the day-ahead
%    economic clearing price.
% 4. The reliability clearing price is retained for sensitivity analysis
%    and is not added to the economic clearing price.
% 5. Grid-export revenue is not included at this stage.

clear;
clc;
close all;

%% 1. Project paths

scriptDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(scriptDir);

dataDir = fullfile(projectDir, 'data');
resultsDir = fullfile(projectDir, 'results');

if ~exist(dataDir, 'dir')
    mkdir(dataDir);
end

if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

sourceWorkbook = ...
    'G:\华润实习\公有数据汇总-20260401_20260630.xlsx';

sheetName = '公有数据汇总';

assert(isfile(sourceWorkbook), ...
    'Source workbook not found: %s', sourceWorkbook);

%% 2. Read only the required source columns

% The workbook has two header rows. Data begin on row 3.
dateRaw = readcell( ...
    sourceWorkbook, ...
    'Sheet', sheetName, ...
    'Range', 'A3:A8738');

timeRaw = readcell( ...
    sourceWorkbook, ...
    'Sheet', sheetName, ...
    'Range', 'B3:B8738');

reliabilityPriceRaw = readmatrix( ...
    sourceWorkbook, ...
    'Sheet', sheetName, ...
    'Range', 'Z3:Z8738');

economicPriceRaw = readmatrix( ...
    sourceWorkbook, ...
    'Sheet', sheetName, ...
    'Range', 'AA3:AA8738');

numberOfRows = numel(economicPriceRaw);

assert(numel(dateRaw) == numberOfRows, ...
    'Date and price columns have different lengths.');

assert(numel(timeRaw) == numberOfRows, ...
    'Time and price columns have different lengths.');

assert(numel(reliabilityPriceRaw) == numberOfRows, ...
    'Reliability-price and economic-price columns have different lengths.');

%% 3. Convert and validate the date-time grain

priceDate = convertDateCells(dateRaw);
timeLabel = convertTimeCells(timeRaw);

[priceDateList, ~, dayGroup] = unique( ...
    priceDate, 'stable');

numberOfDays = numel(priceDateList);
rowsPerDay = accumarray(dayGroup, 1);

expectedIntervalsPerDay = 96;
expectedRows = numberOfDays * expectedIntervalsPerDay;

assert(numberOfRows == expectedRows, ...
    ['Unexpected row count. Expected %d rows for %d days, ' ...
     'but found %d.'], ...
    expectedRows, numberOfDays, numberOfRows);

assert(all(rowsPerDay == expectedIntervalsPerDay), ...
    'At least one date does not contain exactly 96 intervals.');

dateTimeKey = string(priceDate, 'yyyy-MM-dd') ...
    + " " + timeLabel;

assert(numel(unique(dateTimeKey)) == numberOfRows, ...
    'Duplicate date-time records were detected.');

%% 4. Repair the missing economic-price day transparently

economicPriceClean = economicPriceRaw;
economicPriceImputed = false(numberOfRows, 1);

missingEconomicMask = isnan(economicPriceRaw);
missingEconomicIndex = find(missingEconomicMask);

for k = reshape(missingEconomicIndex, 1, [])

    neighbourValues = [];

    % Previous day, same 15-minute settlement interval
    if k > expectedIntervalsPerDay
        previousValue = ...
            economicPriceRaw(k - expectedIntervalsPerDay);

        if ~isnan(previousValue)
            neighbourValues(end + 1) = previousValue; %#ok<SAGROW>
        end
    end

    % Next day, same 15-minute settlement interval
    if k <= numberOfRows - expectedIntervalsPerDay
        nextValue = ...
            economicPriceRaw(k + expectedIntervalsPerDay);

        if ~isnan(nextValue)
            neighbourValues(end + 1) = nextValue; %#ok<SAGROW>
        end
    end

    if isempty(neighbourValues)

        % Fallback: median of the same settlement interval
        % across all available days.
        settlementIndex = ...
            mod(k - 1, expectedIntervalsPerDay) + 1;

        sameIntervalValues = economicPriceRaw( ...
            settlementIndex:expectedIntervalsPerDay:end);

        economicPriceClean(k) = ...
            simplePercentile(sameIntervalValues, 50);

    else

        economicPriceClean(k) = mean(neighbourValues);

    end

    economicPriceImputed(k) = true;

end


assert(~any(isnan(economicPriceClean)), ...
    'Economic-price cleaning left one or more NaN values.');

assert(~any(isnan(reliabilityPriceRaw)), ...
    'Reliability price unexpectedly contains missing values.');

%% 5. Reshape the 91-day data into 96 intervals x number of days

economicPriceRaw_96xN = reshape( ...
    economicPriceRaw, expectedIntervalsPerDay, numberOfDays);

economicPriceClean_96xN = reshape( ...
    economicPriceClean, expectedIntervalsPerDay, numberOfDays);

reliabilityPrice_96xN = reshape( ...
    reliabilityPriceRaw, expectedIntervalsPerDay, numberOfDays);

economicPriceImputed_96xN = reshape( ...
    economicPriceImputed, expectedIntervalsPerDay, numberOfDays);

settlementTime_h = (0.25:0.25:24)';

%% 6. Calculate price thresholds for the rule-based EMS

economicPriceP25_RMB_MWh = ...
    simplePercentile(economicPriceClean, 25);

economicPriceMedian_RMB_MWh = ...
    simplePercentile(economicPriceClean, 50);

economicPriceP75_RMB_MWh = ...
    simplePercentile(economicPriceClean, 75);

dailyLowPriceThreshold_RMB_MWh = zeros(numberOfDays, 1);
dailyHighPriceThreshold_RMB_MWh = zeros(numberOfDays, 1);

for dayIndex = 1:numberOfDays

    dailyLowPriceThreshold_RMB_MWh(dayIndex) = ...
        simplePercentile( ...
        economicPriceClean_96xN(:, dayIndex), 25);

    dailyHighPriceThreshold_RMB_MWh(dayIndex) = ...
        simplePercentile( ...
        economicPriceClean_96xN(:, dayIndex), 75);

end


%% 7. Create one continuous zero-order-hold price timeseries

dt = 900;

continuousTime_sec = ...
    (0:dt:numberOfRows * dt)';

% Prices are labelled by interval end time (00:15 ... 24:00).
% The first price therefore applies from 00:00 to 00:15.
continuousEconomicPrice = [ ...
    economicPriceClean; ...
    economicPriceClean(end)];

day_ahead_economic_price_91day = timeseries( ...
    continuousEconomicPrice, continuousTime_sec);

day_ahead_economic_price_91day = setinterpmethod( ...
    day_ahead_economic_price_91day, 'zoh');

%% 8. Save the cleaned and auditable dataset

marketName = "Shandong, China";
currency = "RMB";
priceUnit = "RMB/MWh";

outputMatFile = fullfile( ...
    dataDir, 'day_ahead_price_data.mat');

save(outputMatFile, ...
    'sourceWorkbook', ...
    'sheetName', ...
    'marketName', ...
    'currency', ...
    'priceUnit', ...
    'priceDateList', ...
    'settlementTime_h', ...
    'economicPriceRaw_96xN', ...
    'economicPriceClean_96xN', ...
    'reliabilityPrice_96xN', ...
    'economicPriceImputed_96xN', ...
    'dailyLowPriceThreshold_RMB_MWh', ...
    'dailyHighPriceThreshold_RMB_MWh', ...
    'economicPriceP25_RMB_MWh', ...
    'economicPriceMedian_RMB_MWh', ...
    'economicPriceP75_RMB_MWh', ...
    'day_ahead_economic_price_91day');

%% 9. Export a data-quality record

missingDateList = unique(priceDate(missingEconomicMask));

qualitySummary = table( ...
    numberOfRows, ...
    numberOfDays, ...
    expectedIntervalsPerDay, ...
    sum(missingEconomicMask), ...
    sum(economicPriceImputed), ...
    min(economicPriceClean), ...
    economicPriceP25_RMB_MWh, ...
    economicPriceMedian_RMB_MWh, ...
    economicPriceP75_RMB_MWh, ...
    max(economicPriceClean), ...
    sum(economicPriceClean < 0), ...
    'VariableNames', { ...
    'Rows', ...
    'Days', ...
    'IntervalsPerDay', ...
    'OriginalMissingEconomicPrices', ...
    'ImputedEconomicPrices', ...
    'MinimumPrice_RMB_MWh', ...
    'P25Price_RMB_MWh', ...
    'MedianPrice_RMB_MWh', ...
    'P75Price_RMB_MWh', ...
    'MaximumPrice_RMB_MWh', ...
    'NegativePriceIntervals'});

qualityCsvFile = fullfile( ...
    resultsDir, 'day_ahead_price_quality_summary.csv');

writetable(qualitySummary, qualityCsvFile);

%% 10. Plot the average daily pattern and the 91-day heatmap

averageEconomicPriceBySlot = mean( ...
    economicPriceClean_96xN, 2);

averageReliabilityPriceBySlot = mean( ...
    reliabilityPrice_96xN, 2);

[minimumAveragePrice, minimumAverageIndex] = ...
    min(averageEconomicPriceBySlot);

[maximumAveragePrice, maximumAverageIndex] = ...
    max(averageEconomicPriceBySlot);

figure( ...
    'Color', 'w', ...
    'Name', 'Shandong Day-ahead Price Data Check');

tiledlayout(2, 1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

nexttile;

economicLine = plot(settlementTime_h, ...
    averageEconomicPriceBySlot, ...
    'b-', 'LineWidth', 2);

hold on;

reliabilityLine = plot(settlementTime_h, ...
    averageReliabilityPriceBySlot, ...
    'k--', 'LineWidth', 1.5);

yline(economicPriceP25_RMB_MWh, ...
    'Color', [0.10 0.60 0.20], ...
    'LineStyle', '--', ...
    'Label', 'Economic-price P25');

yline(economicPriceP75_RMB_MWh, ...
    'Color', [0.85 0.20 0.15], ...
    'LineStyle', '--', ...
    'Label', 'Economic-price P75');

grid on;
xlim([0 24]);
xlabel('Time of day (h)');
ylabel('Price (RMB/MWh)');
title('Average 15-minute Day-ahead Price Pattern');
legend([economicLine reliabilityLine], ...
    'Economic clearing price', ...
    'Reliability clearing price', ...
    'Location', 'best');

nexttile;

imagesc( ...
    settlementTime_h, ...
    1:numberOfDays, ...
    economicPriceClean_96xN');

set(gca, 'YDir', 'normal');

colorbar;

lowerColorLimit = ...
    simplePercentile(economicPriceClean, 5);

upperColorLimit = ...
    simplePercentile(economicPriceClean, 95);

clim([lowerColorLimit upperColorLimit]);

xlabel('Time of day (h)');
ylabel('Day index');
title('91-day Economic Clearing Price Heatmap');

sgtitle( ...
    'Shandong Day-ahead Price Dataset for Price-aware PV-BESS EMS');

priceFigureFile = fullfile( ...
    resultsDir, 'day_ahead_price_data_check.png');

exportgraphics(gcf, priceFigureFile, 'Resolution', 200);

%% 11. Command-window validation summary

fprintf('\n--- Shandong Day-ahead Price Data Check ---\n');
fprintf('Date range: %s to %s\n', ...
    string(priceDateList(1), 'yyyy-MM-dd'), ...
    string(priceDateList(end), 'yyyy-MM-dd'));
fprintf('Rows: %d\n', numberOfRows);
fprintf('Days: %d\n', numberOfDays);
fprintf('Intervals per day: %d\n', expectedIntervalsPerDay);
fprintf('Duplicate date-time keys: 0\n');
fprintf('Missing economic-price intervals: %d\n', ...
    sum(missingEconomicMask));
fprintf('Imputed economic-price intervals: %d\n', ...
    sum(economicPriceImputed));

if ~isempty(missingDateList)
    fprintf('Affected date(s): %s\n', ...
        strjoin(string(missingDateList, 'yyyy-MM-dd'), ', '));
end

fprintf('Economic-price range: %.2f to %.2f RMB/MWh\n', ...
    min(economicPriceClean), max(economicPriceClean));
fprintf('Economic-price P25 / median / P75: %.2f / %.2f / %.2f RMB/MWh\n', ...
    economicPriceP25_RMB_MWh, ...
    economicPriceMedian_RMB_MWh, ...
    economicPriceP75_RMB_MWh);
fprintf('Negative-price intervals: %d\n', ...
    sum(economicPriceClean < 0));
fprintf('Lowest average price time: %.2f h (%.2f RMB/MWh)\n', ...
    settlementTime_h(minimumAverageIndex), minimumAveragePrice);
fprintf('Highest average price time: %.2f h (%.2f RMB/MWh)\n', ...
    settlementTime_h(maximumAverageIndex), maximumAveragePrice);
fprintf('MAT file saved to:\n%s\n', outputMatFile);
fprintf('Quality summary saved to:\n%s\n', qualityCsvFile);
fprintf('Figure saved to:\n%s\n\n', priceFigureFile);


%% Local functions

function outputDate = convertDateCells(inputCells)

numberOfValues = numel(inputCells);
outputDate = NaT(numberOfValues, 1);

for rowIndex = 1:numberOfValues

    currentValue = inputCells{rowIndex};

    if isdatetime(currentValue)

        outputDate(rowIndex) = dateshift( ...
            currentValue, 'start', 'day');

    elseif isnumeric(currentValue)

        outputDate(rowIndex) = dateshift( ...
            datetime(currentValue, 'ConvertFrom', 'excel'), ...
            'start', 'day');

    else

        outputDate(rowIndex) = datetime( ...
            string(currentValue), ...
            'InputFormat', 'yyyy-MM-dd');

    end

end

end


function outputTime = convertTimeCells(inputCells)

numberOfValues = numel(inputCells);
outputTime = strings(numberOfValues, 1);

for rowIndex = 1:numberOfValues

    currentValue = inputCells{rowIndex};

    if isduration(currentValue)

        totalMinutes = round(minutes(currentValue));
        hourValue = floor(totalMinutes / 60);
        minuteValue = mod(totalMinutes, 60);

        outputTime(rowIndex) = sprintf( ...
            '%02d:%02d', hourValue, minuteValue);

    elseif isdatetime(currentValue)

        outputTime(rowIndex) = string( ...
            currentValue, 'HH:mm');

    elseif isnumeric(currentValue)

        totalMinutes = round(24 * 60 * currentValue);
        hourValue = floor(totalMinutes / 60);
        minuteValue = mod(totalMinutes, 60);

        outputTime(rowIndex) = sprintf( ...
            '%02d:%02d', hourValue, minuteValue);

    else

        outputTime(rowIndex) = strip(string(currentValue));

    end

end

end


function percentileValue = simplePercentile(inputValues, percentile)

cleanValues = inputValues(~isnan(inputValues));
cleanValues = sort(cleanValues(:));

assert(~isempty(cleanValues), ...
    'Cannot calculate a percentile from an empty vector.');

position = 1 + ...
    (numel(cleanValues) - 1) * percentile / 100;

lowerIndex = floor(position);
upperIndex = ceil(position);

if lowerIndex == upperIndex

    percentileValue = cleanValues(lowerIndex);

else

    fraction = position - lowerIndex;

    percentileValue = ...
        cleanValues(lowerIndex) ...
        + fraction * ( ...
        cleanValues(upperIndex) ...
        - cleanValues(lowerIndex));

end

end
