%% initialize_price_aware_project.m
% Initialize one-day price-aware PV-BESS EMS simulation.

clc;
close all;

%% 1. Project paths

scriptDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(scriptDir);

dataDir = fullfile(projectDir, 'data');
modelDir = fullfile(projectDir, 'model');

addpath(modelDir);

%% 2. Load input data

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData = load(fullfile(dataDir, 'pv_profile.mat'));
priceData = load(fullfile(dataDir, ...
    'day_ahead_price_data.mat'));

load_profile = loadData.load_profile;
pv_profile = pvData.pv_profile;

%% 3. Selected engineering design

% Variable names currently used by the Simulink Constant blocks
E_batt_kWh = 340;
P_batt_max_kW = 70;
P_grid_limit_kW = 100;
SOC_initial = 0.50;

% Compatibility aliases used by previous scripts and equations
E_batt = E_batt_kWh;
P_batt_max = P_batt_max_kW;
P_grid_limit = P_grid_limit_kW;

%% 4. Select one day of day-ahead prices

priceDayIndex = 1;

assert(priceDayIndex >= 1 && ...
    priceDayIndex <= numel(priceData.priceDateList), ...
    'priceDayIndex is outside the available dataset.');

priceVector96 = ...
    priceData.economicPriceClean_96xN(:, priceDayIndex);

% Add the 24:00 endpoint so the signal covers the complete simulation.
priceTime_sec = (0:900:86400)';

price_profile = timeseries( ...
    [priceVector96; priceVector96(end)], ...
    priceTime_sec);

% Price is settled in 15-minute intervals, so use zero-order hold.
price_profile = setinterpmethod(price_profile, 'zoh');

% Daily P25 price threshold prepared during data cleaning.
price_low_threshold_RMB_MWh = ...
    priceData.dailyLowPriceThreshold_RMB_MWh(priceDayIndex);

%% 5. EMS mode switches

% Existing forecast/state request.
precharge_enable = 1;

% 0: original fixed 00:00-06:00 grid precharging
% 1: price-aware grid precharging
price_aware_enable = 0;

%% 6. Print initialization summary

fprintf('\n--- Price-aware PV-BESS Project Initialized ---\n');

fprintf('BESS design: %.0f kWh / %.0f kW\n', ...
    E_batt, P_batt_max);

fprintf('Grid-import limit: %.0f kW\n', ...
    P_grid_limit);

fprintf('Initial SOC: %.1f %%\n', ...
    100 * SOC_initial);

fprintf('Price date: %s\n', ...
    string(priceData.priceDateList(priceDayIndex), ...
    'yyyy-MM-dd'));

fprintf('Daily low-price threshold: %.2f RMB/MWh\n', ...
    price_low_threshold_RMB_MWh);

fprintf('Precharge enabled: %d\n', ...
    precharge_enable);

fprintf('Price-aware mode: %d\n\n', ...
    price_aware_enable);