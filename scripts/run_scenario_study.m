%% PV-BESS multi-scenario study
clc; close all;

% Configure simulation logging
Simulink.sdi.clear(Export=false);
Simulink.sdi.setStorageMode("memory");
Simulink.sdi.setRecordData(true);

% Project folders
scriptFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptFolder);
dataFolder = fullfile(projectRoot, 'data');
modelFolder = fullfile(projectRoot, 'model');
resultsFolder = fullfile(projectRoot, 'results');

% Load original profiles
loadData = load(fullfile(dataFolder, 'load_profile.mat'));
pvData = load(fullfile(dataFolder, 'pv_profile.mat'));

inputTime = loadData.t(:);
P_Load_base = loadData.P_Load(:);
P_PV_base = pvData.P_PV(:);

assert(numel(inputTime) == numel(P_Load_base), ...
    'Load time and power vectors do not match.');

assert(numel(inputTime) == numel(P_PV_base), ...
    'PV time and power vectors do not match.');

% Recommended BESS configuration
E_batt_kWh = 200;
P_batt_max_kW = 50;
P_grid_limit_kW = 100;

eta_ch = 0.95;
eta_dis = 0.95;

% Scenario definitions
Scenario = [ ...
    "Sunny / Normal Load"
    "Cloudy / Normal Load"
    "Sunny / High Load"
    "Cloudy / High Load"];

PVFactor = [1.00; 0.55; 1.00; 0.55];
LoadFactor = [1.00; 1.00; 1.15; 1.15];
% Enable forecast-based precharging for stressful scenarios
PrechargeEnable = [0; 1; 1; 1];

nScenarios = numel(Scenario);

% Results
PeakGrid_kW = zeros(nScenarios, 1);
MeetsGridLimit = false(nScenarios, 1);
GridExceedance_kWh = zeros(nScenarios, 1);
PVSelfConsumption_pct = zeros(nScenarios, 1);
InitialSOC_pct = zeros(nScenarios, 1);
FinalSOC_pct = zeros(nScenarios, 1);
MinSOC_pct = zeros(nScenarios, 1);
MaxSOC_pct = zeros(nScenarios, 1);
AdjustedGridImport_kWh = zeros(nScenarios, 1);
AdjustedImportReduction_pct = zeros(nScenarios, 1);

% Load model
modelName = 'PV_BESS_EMS';
modelFile = fullfile(modelFolder, [modelName '.slx']);

load_system(modelFile);
set_param(modelName, 'FastRestart', 'off');

for k = 1:nScenarios

    fprintf('\nRunning scenario %d of %d: %s\n', ...
        k, nScenarios, Scenario(k));

    % Create scenario-specific profiles
    P_Load_scenario = P_Load_base * LoadFactor(k);
    P_PV_scenario = P_PV_base * PVFactor(k);
    precharge_enable = PrechargeEnable(k);

    % These names are used by the From Workspace blocks
    load_profile = timeseries(P_Load_scenario, inputTime);
    pv_profile = timeseries(P_PV_scenario, inputTime);

    % Remove previous temporary simulation record
    Simulink.sdi.clear(Export=false);
    Simulink.sdi.setRecordData(true);

    % Run model
    simOut = sim(modelName, 'StopTime', '86400');

    % Extract simulation results
    P_grid_base_ts = simOut.P_grid_base_sim;
    P_grid_ems_ts = simOut.P_grid_ems_sim;
    SOC_ts = simOut.SOC_sim;

    simulationTime = P_grid_ems_ts.Time;

    P_grid_base = P_grid_base_ts.Data(:);
    P_grid_ems = P_grid_ems_ts.Data(:);
    SOC = SOC_ts.Data(:);

    if isempty(SOC)
        error('SOC data is empty for scenario: %s', Scenario(k));
    end

    % Grid power KPIs
    peakGrid = max(P_grid_ems);

    gridImportBase = ...
        trapz(simulationTime, max(P_grid_base, 0)) / 3600;

    gridImportEMS = ...
        trapz(simulationTime, max(P_grid_ems, 0)) / 3600;

    gridExportEMS = ...
        trapz(simulationTime, max(-P_grid_ems, 0)) / 3600;

    exceedancePower = ...
        max(P_grid_ems - P_grid_limit_kW, 0);

    exceedanceEnergy = ...
        trapz(simulationTime, exceedancePower) / 3600;

    % PV self-consumption
    pvEnergy = ...
        trapz(inputTime, P_PV_scenario) / 3600;

    if pvEnergy > 0
        pvSelfConsumption = ...
            100 * (pvEnergy - gridExportEMS) / pvEnergy;
    else
        pvSelfConsumption = NaN;
    end

    % Terminal SOC correction
    socInitial = SOC(1);
    socFinal = SOC(end);

    if socFinal < socInitial
        terminalCorrection = ...
            (socInitial - socFinal) ...
            * E_batt_kWh / eta_ch;
    else
        terminalCorrection = ...
            -(socFinal - socInitial) ...
            * E_batt_kWh * eta_dis;
    end

    adjustedGridImport = ...
        gridImportEMS + terminalCorrection;

    adjustedReduction = 100 * ...
        (gridImportBase - adjustedGridImport) ...
        / gridImportBase;

    % Save metrics
    PeakGrid_kW(k) = peakGrid;

    MeetsGridLimit(k) = ...
        peakGrid <= P_grid_limit_kW + 0.01;

    GridExceedance_kWh(k) = exceedanceEnergy;
    PVSelfConsumption_pct(k) = pvSelfConsumption;

    InitialSOC_pct(k) = socInitial * 100;
    FinalSOC_pct(k) = socFinal * 100;
    MinSOC_pct(k) = min(SOC) * 100;
    MaxSOC_pct(k) = max(SOC) * 100;

    AdjustedGridImport_kWh(k) = ...
        adjustedGridImport;

    AdjustedImportReduction_pct(k) = ...
        adjustedReduction;
end

% Assemble result table
scenarioResults = table( ...
    Scenario, ...
    PVFactor, ...
    LoadFactor, ...
    PrechargeEnable, ...
    PeakGrid_kW, ...
    MeetsGridLimit, ...
    GridExceedance_kWh, ...
    PVSelfConsumption_pct, ...
    InitialSOC_pct, ...
    FinalSOC_pct, ...
    MinSOC_pct, ...
    MaxSOC_pct, ...
    AdjustedGridImport_kWh, ...
    AdjustedImportReduction_pct);

fprintf('\n--- Multi-scenario Study Results ---\n');
disp(scenarioResults);
fprintf('\n--- Multi-scenario Study Results ---\n');
disp(scenarioResults);
fprintf('\n--- Key Validation Columns ---\n');

disp(scenarioResults(:, { ...
    'Scenario', ...
    'PrechargeEnable', ...
    'PeakGrid_kW', ...
    'MeetsGridLimit', ...
    'MinSOC_pct', ...
    'FinalSOC_pct', ...
    'MaxSOC_pct'}));

% Save table
writetable(scenarioResults, ...
    fullfile(resultsFolder, 'scenario_study_results.csv'));

save(fullfile(resultsFolder, 'scenario_study_results.mat'), ...
    'scenarioResults');

% Peak grid comparison chart
fig1 = figure('Color', 'w');

scenarioCategory = categorical(Scenario, Scenario);

bar(scenarioCategory, PeakGrid_kW, ...
    'FaceColor', [0.20 0.50 0.80]);

hold on;

yline(P_grid_limit_kW, 'r--', ...
    '100 kW Grid Limit', ...
    'LineWidth', 1.8);

grid on;
ylabel('Peak grid import (kW)');
title('Peak Grid Import under Different Operating Scenarios');
ylim([0 max(PeakGrid_kW) + 20]);
ax = gca;
ax.XTickLabelRotation = 15;

exportgraphics(fig1, ...
    fullfile(resultsFolder, ...
    'scenario_peak_grid_comparison.png'), ...
    'Resolution', 300);

% SOC comparison chart
fig2 = figure('Color', 'w');

bar(scenarioCategory, ...
    [MinSOC_pct FinalSOC_pct MaxSOC_pct]);

grid on;
ylabel('SOC (%)');
title('Battery SOC under Different Operating Scenarios');
legend('Minimum SOC', 'Final SOC', 'Maximum SOC', ...
    'Location', 'best');
ax = gca;
ax.XTickLabelRotation = 15;

exportgraphics(fig2, ...
    fullfile(resultsFolder, ...
    'scenario_soc_comparison.png'), ...
    'Resolution', 300);

fprintf('\nScenario study completed.\n');
fprintf('Results saved in: %s\n', resultsFolder);