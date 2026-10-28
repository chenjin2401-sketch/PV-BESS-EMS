clc; close all;

% Simulation time settings
dt = 900;                     % 15 minutes
T_end = 24 * 3600;            % 24 hours
t = (0:dt:T_end)';
hour = t / 3600;

% PV system rating
P_PV_rated = 130;             % kW

% PV generation: sunrise 06:00, sunset 18:00
P_PV = zeros(size(t));
daylight = (hour >= 6) & (hour <= 18);

normalized_solar = sin(pi * (hour(daylight) - 6) / 12);
P_PV(daylight) = P_PV_rated * normalized_solar.^1.5;

% Safety check
P_PV(P_PV < 0) = 0;

% Package data for Simulink
pv_profile = timeseries(P_PV, t);

% Daily PV energy generation
E_PV_kWh = trapz(t, P_PV) / 3600;

% Plot
figure('Color', 'w');
plot(hour, P_PV, 'Color', [0.85 0.45 0], 'LineWidth', 2);
grid on;
xlim([0 24]);
ylim([0 150]);
xlabel('Time of day (h)');
ylabel('PV power (kW)');
title('Clear-sky PV Generation Profile');

% Save data robustly, independent of current working folder
scriptFolder = fileparts(mfilename('fullpath'));
projectFolder = fileparts(scriptFolder);
dataFolder = fullfile(projectFolder, 'data');

save(fullfile(dataFolder, 'pv_profile.mat'), ...
    'pv_profile', 't', 'hour', 'P_PV', 'dt', ...
    'P_PV_rated', 'E_PV_kWh');

fprintf('Daily PV generation = %.1f kWh\n', E_PV_kWh);
fprintf('PV rated power = %.1f kW\n', P_PV_rated);