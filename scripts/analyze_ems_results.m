clc; close all;

% Check that Simulink output is available
assert(exist('out', 'var') == 1, ...
    'Run the Simulink model first.');

% Extract results from the SimulationOutput object
P_grid_base_sim = out.P_grid_base_sim;
P_grid_ems_sim = out.P_grid_ems_sim;
P_batt_sim = out.P_batt_sim;
SOC_sim = out.SOC_sim;

% Read simulation outputs
t = P_grid_base_sim.Time;
hour = t / 3600;

P_grid_base = P_grid_base_sim.Data(:);
P_grid_ems = P_grid_ems_sim.Data(:);
P_batt = P_batt_sim.Data(:);
SOC = SOC_sim.Data(:);

% Read original load and PV profiles
projectRoot = fileparts(fileparts(mfilename('fullpath')));

loadData = load(fullfile(projectRoot, 'data', 'load_profile.mat'));
pvData = load(fullfile(projectRoot, 'data', 'pv_profile.mat'));

P_Load = loadData.P_Load(:);
P_PV = pvData.P_PV(:);

% Energy and power KPIs
E_grid_import_base = trapz(t, max(P_grid_base, 0)) / 3600;
E_grid_import_ems = trapz(t, max(P_grid_ems, 0)) / 3600;

E_grid_export_base = trapz(t, max(-P_grid_base, 0)) / 3600;
E_grid_export_ems = trapz(t, max(-P_grid_ems, 0)) / 3600;

E_PV = trapz(t, P_PV) / 3600;

PV_self_consumption_base = ...
    100 * (E_PV - E_grid_export_base) / E_PV;

PV_self_consumption_ems = ...
    100 * (E_PV - E_grid_export_ems) / E_PV;

Peak_grid_base = max(P_grid_base);
Peak_grid_ems = max(P_grid_ems);
Peak_reduction_pct = ...
    100 * (Peak_grid_base - Peak_grid_ems) / Peak_grid_base;

Battery_throughput_kWh = trapz(t, abs(P_batt)) / 3600;

% Power-balance validation
power_balance_error = P_Load - P_PV - P_batt - P_grid_ems;
max_power_balance_error = max(abs(power_balance_error));

% Print results
fprintf('\n--- PV-BESS EMS KPI Summary ---\n');
fprintf('Baseline peak grid import: %.1f kW\n', Peak_grid_base);
fprintf('EMS peak grid import: %.1f kW\n', Peak_grid_ems);
fprintf('Peak reduction: %.1f %%\n', Peak_reduction_pct);
fprintf('\n');

fprintf('Baseline grid import: %.1f kWh\n', E_grid_import_base);
fprintf('EMS grid import: %.1f kWh\n', E_grid_import_ems);
fprintf('\n');

fprintf('Baseline PV self-consumption: %.1f %%\n', ...
    PV_self_consumption_base);
fprintf('EMS PV self-consumption: %.1f %%\n', ...
    PV_self_consumption_ems);
fprintf('\n');

fprintf('Battery throughput: %.1f kWh\n', Battery_throughput_kWh);
fprintf('SOC range: %.1f %% to %.1f %%\n', ...
    min(SOC) * 100, max(SOC) * 100);
fprintf('Maximum power-balance error: %.6f kW\n', ...
    max_power_balance_error);

% Comparison figure
figure('Color', 'w');
plot(hour, P_grid_base, 'k--', 'LineWidth', 1.8);
hold on;
plot(hour, P_grid_ems, 'b-', 'LineWidth', 2);
yline(100, 'r--', '100 kW Grid Limit', 'LineWidth', 1.5);
grid on;
xlim([0 24]);
xlabel('Time of day (h)');
ylabel('Grid power (kW)');
title('Grid Power: Baseline vs Rule-based EMS');
legend('Baseline', 'With EMS', 'Grid limit', ...
    'Location', 'northwest');

% Save result data
resultsFolder = fullfile(projectRoot, 'results');

save(fullfile(resultsFolder, 'ems_kpi_results.mat'), ...
    'E_grid_import_base', 'E_grid_import_ems', ...
    'E_grid_export_base', 'E_grid_export_ems', ...
    'PV_self_consumption_base', 'PV_self_consumption_ems', ...
    'Peak_grid_base', 'Peak_grid_ems', 'Peak_reduction_pct', ...
    'Battery_throughput_kWh', 'SOC', ...
    'max_power_balance_error');

exportgraphics(gcf, ...
    fullfile(resultsFolder, 'grid_power_comparison.png'), ...
    'Resolution', 300);