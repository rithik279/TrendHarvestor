"""
Prop Firm Trade Audit — HFT, Latency Arbitrage, Consistency Check
FundedNext Stellar 2-Step & FXIFY
"""
import re
from datetime import datetime, timedelta
from collections import defaultdict

RAW_DATA = """
2026.02.09 16:22:17	3438628169	XAUUSDm	buy	0.01	5 073.834			2026.02.09 16:22:32	5 072.563	0.00	0.00	- 1.27
2026.02.09 16:22:18	3438628654	XAUUSDm	buy	0.11	5 072.936			2026.02.09 16:22:32	5 072.563	0.00	0.00	- 4.11
2026.02.09 16:22:26	3438630290	XAUUSDm	buy	0.21	5 072.310			2026.02.09 16:22:31	5 072.563	0.00	0.00	 5.31
2026.02.09 16:22:32	3438631258	XAUUSDm	buy	0.01	5 072.803			2026.02.09 16:24:39	5 074.800	0.00	0.00	 2.00
2026.02.09 16:24:40	3438648109	XAUUSDm	buy	0.01	5 075.040			2026.02.09 16:25:43	5 074.692	0.00	0.00	- 0.35
2026.02.09 16:24:44	3438648888	XAUUSDm	buy	0.11	5 074.557			2026.02.09 16:25:42	5 074.453	0.00	0.00	- 1.15
2026.02.09 16:25:01	3438650940	XAUUSDm	buy	0.21	5 074.251			2026.02.09 16:25:42	5 074.453	0.00	0.00	 4.24
2026.02.09 16:25:43	3438657180	XAUUSDm	buy	0.01	5 074.932			2026.02.09 16:25:50	5 077.081	0.00	0.00	 2.15
2026.02.09 16:25:50	3438661580	XAUUSDm	buy	0.01	5 077.292			2026.02.09 16:25:52	5 077.427	0.00	0.00	 0.14
2026.02.09 16:25:52	3438663407	XAUUSDm	buy	0.01	5 077.524			2026.02.09 16:26:01	5 079.499	0.00	0.00	 1.98
2026.02.09 16:26:02	3438667378	XAUUSDm	buy	0.01	5 079.446			2026.02.09 16:26:07	5 078.710	0.00	0.00	- 0.74
2026.02.09 16:26:03	3438667933	XAUUSDm	buy	0.11	5 078.936			2026.02.09 16:26:06	5 078.710	0.00	0.00	- 2.49
2026.02.09 16:26:04	3438668345	XAUUSDm	buy	0.21	5 078.594			2026.02.09 16:26:06	5 078.710	0.00	0.00	 2.44
2026.02.09 16:26:07	3438668827	XAUUSDm	buy	0.01	5 078.913			2026.02.09 16:26:15	5 078.876	0.00	0.00	- 0.03
2026.02.09 16:26:11	3438670095	XAUUSDm	buy	0.11	5 077.682			2026.02.09 16:26:14	5 078.674	0.00	0.00	 10.91
2026.02.09 16:26:13	3438670437	XAUUSDm	buy	0.21	5 078.853			2026.02.09 16:26:14	5 078.978	0.00	0.00	 2.63
2026.02.09 16:26:15	3438671157	XAUUSDm	buy	0.01	5 079.236			2026.02.09 16:39:14	5 074.837	0.00	0.00	- 4.40
2026.02.09 16:26:16	3438671279	XAUUSDm	buy	0.11	5 078.808			2026.02.09 16:39:14	5 074.837	0.00	0.00	- 43.68
2026.02.09 16:26:19	3438671844	XAUUSDm	buy	0.21	5 078.244			2026.02.09 16:39:13	5 074.824	0.00	0.00	- 71.82
2026.02.09 16:32:23	3438737224	XAUUSDm	sell	0.01	5 069.210			2026.02.09 16:32:31	5 069.234	0.00	0.00	- 0.02
2026.02.09 16:32:26	3438738297	XAUUSDm	sell	0.11	5 069.826			2026.02.09 16:32:31	5 069.325	0.00	0.00	 5.51
2026.02.09 16:32:31	3438739313	XAUUSDm	sell	0.01	5 068.998			2026.02.09 16:33:32	5 070.605	0.00	0.00	- 1.61
2026.02.09 16:33:23	3438745978	XAUUSDm	sell	0.11	5 071.123			2026.02.09 16:33:32	5 070.468	0.00	0.00	 7.20
2026.02.09 16:33:55	3438750505	XAUUSDm	sell	0.01	5 068.942			2026.02.09 16:34:12	5 069.103	0.00	0.00	- 0.16
2026.02.09 16:33:58	3438750885	XAUUSDm	sell	0.11	5 069.176			2026.02.09 16:34:11	5 069.000	0.00	0.00	 1.94
2026.02.09 16:34:12	3438753334	XAUUSDm	sell	0.01	5 068.863			2026.02.09 16:35:27	5 069.803	0.00	0.00	- 0.94
2026.02.09 16:35:09	3438762766	XAUUSDm	sell	0.11	5 068.200			2026.02.09 16:35:27	5 069.538	0.00	0.00	- 14.72
2026.02.09 16:35:11	3438763338	XAUUSDm	sell	0.21	5 069.261			2026.02.09 16:35:27	5 069.538	0.00	0.00	- 5.82
2026.02.09 16:35:12	3438763495	XAUUSDm	buy	0.31	5 069.649			2026.02.09 16:39:13	5 074.464	0.00	0.00	 149.26
2026.02.09 16:35:19	3438764962	XAUUSDm	sell	0.31	5 070.110			2026.02.09 16:35:26	5 069.538	0.00	0.00	 17.73
2026.02.09 16:35:30	3438766574	XAUUSDm	sell	0.01	5 069.220			2026.02.09 16:35:36	5 069.841	0.00	0.00	- 0.62
2026.02.09 16:35:32	3438766964	XAUUSDm	sell	0.11	5 069.895			2026.02.09 16:35:35	5 069.841	0.00	0.00	 0.60
2026.02.09 16:35:34	3438767293	XAUUSDm	sell	0.21	5 070.125			2026.02.09 16:35:35	5 069.841	0.00	0.00	 5.97
2026.02.09 16:35:53	3438769270	XAUUSDm	sell	0.01	5 069.116			2026.02.09 16:36:22	5 069.689	0.00	0.00	- 0.57
2026.02.09 16:35:58	3438769570	XAUUSDm	sell	0.11	5 069.710			2026.02.09 16:36:22	5 069.689	0.00	0.00	 0.23
2026.02.09 16:36:08	3438770448	XAUUSDm	sell	0.21	5 070.237			2026.02.09 16:36:21	5 069.772	0.00	0.00	 9.77
2026.02.09 16:39:14	3438794975	XAUUSDm	buy	0.01	5 075.077			2026.02.09 16:39:29	5 074.407	0.00	0.00	- 0.67
2026.02.09 16:39:17	3438795692	XAUUSDm	buy	0.11	5 074.761			2026.02.09 16:39:28	5 074.407	0.00	0.00	- 3.89
2026.02.09 16:39:20	3438796392	XAUUSDm	buy	0.21	5 074.554			2026.02.09 16:39:28	5 074.407	0.00	0.00	- 3.08
2026.02.09 16:39:29	3438797435	XAUUSDm	buy	0.01	5 074.609			2026.02.09 16:39:48	5 074.682	0.00	0.00	 0.07
2026.02.09 16:39:44	3438798999	XAUUSDm	buy	0.11	5 074.330			2026.02.09 16:39:48	5 074.682	0.00	0.00	 3.87
2026.02.09 16:39:49	3438799439	XAUUSDm	buy	0.01	5 074.951			2026.02.09 16:40:15	5 075.172	0.00	0.00	 0.22
2026.02.09 16:40:14	3438804003	XAUUSDm	buy	0.11	5 074.566			2026.02.09 16:40:15	5 075.043	0.00	0.00	 5.24
2026.02.09 16:40:15	3438804224	XAUUSDm	buy	0.01	5 075.532			2026.02.09 16:41:21	5 074.480	0.00	0.00	- 1.05
2026.02.09 16:40:20	3438804653	XAUUSDm	buy	0.11	5 075.016			2026.02.09 16:41:21	5 074.480	0.00	0.00	- 5.90
2026.02.09 16:40:29	3438805362	XAUUSDm	buy	0.21	5 074.730			2026.02.09 16:41:21	5 074.554	0.00	0.00	- 3.70
2026.02.09 16:41:22	3438812460	XAUUSDm	buy	0.01	5 074.407			2026.02.09 16:41:51	5 073.655	0.00	0.00	- 0.75
2026.02.09 16:41:28	3438813079	XAUUSDm	buy	0.11	5 074.129			2026.02.09 16:41:50	5 073.933	0.00	0.00	- 2.16
2026.02.09 16:41:31	3438813447	XAUUSDm	buy	0.21	5 073.695			2026.02.09 16:41:50	5 073.933	0.00	0.00	 4.99
2026.02.09 16:41:51	3438815642	XAUUSDm	buy	0.01	5 073.964			2026.02.09 16:42:02	5 075.145	0.00	0.00	 1.19
2026.02.09 16:41:55	3438816037	XAUUSDm	buy	0.11	5 073.678			2026.02.09 16:42:01	5 074.725	0.00	0.00	 11.52
2026.02.09 16:42:02	3438817160	XAUUSDm	buy	0.01	5 075.780			2026.02.09 16:42:10	5 075.313	0.00	0.00	- 0.47
2026.02.09 16:42:03	3438817280	XAUUSDm	buy	0.11	5 075.219			2026.02.09 16:42:10	5 075.313	0.00	0.00	 1.03
2026.02.09 16:42:11	3438818452	XAUUSDm	buy	0.01	5 075.704			2026.02.09 16:42:45	5 075.470	0.00	0.00	- 0.23
2026.02.09 16:42:20	3438820863	XAUUSDm	buy	0.11	5 075.464			2026.02.09 16:42:44	5 075.668	0.00	0.00	 2.25
2026.02.09 16:42:25	3438821490	XAUUSDm	buy	0.21	5 075.425			2026.02.09 16:42:44	5 075.668	0.00	0.00	 5.10
2026.02.09 16:42:45	3438824819	XAUUSDm	buy	0.01	5 075.829			2026.02.09 16:43:10	5 076.018	0.00	0.00	 0.19
2026.02.09 16:43:08	3438828742	XAUUSDm	buy	0.11	5 075.259			2026.02.09 16:43:10	5 075.516	0.00	0.00	 2.83
2026.02.09 16:43:10	3438829236	XAUUSDm	buy	0.01	5 076.378			2026.02.09 16:43:16	5 076.338	0.00	0.00	- 0.04
2026.02.09 16:43:12	3438829382	XAUUSDm	buy	0.11	5 076.008			2026.02.09 16:43:16	5 076.338	0.00	0.00	 3.63
2026.02.09 16:43:17	3438829911	XAUUSDm	buy	0.01	5 076.462			2026.02.09 16:44:36	5 078.373	0.00	0.00	 1.91
2026.02.09 16:44:36	3438844628	XAUUSDm	buy	0.01	5 078.087			2026.02.09 16:45:00	5 077.071	0.00	0.00	- 1.02
2026.02.09 16:44:43	3438845957	XAUUSDm	buy	0.11	5 077.809			2026.02.09 16:45:00	5 078.101	0.00	0.00	 3.21
2026.02.09 16:45:01	3438848261	XAUUSDm	buy	0.01	5 077.365			2026.02.09 16:45:04	5 076.934	0.00	0.00	- 0.44
2026.02.09 16:45:02	3438848445	XAUUSDm	buy	0.11	5 076.950			2026.02.09 16:45:04	5 076.764	0.00	0.00	- 2.05
2026.02.09 16:45:04	3438848945	XAUUSDm	buy	0.01	5 077.081			2026.02.09 16:45:14	5 079.061	0.00	0.00	 1.98
2026.02.09 16:45:14	3438852375	XAUUSDm	buy	0.01	5 079.363			2026.02.09 16:45:25	5 078.060	0.00	0.00	- 1.30
2026.02.09 16:45:19	3438855474	XAUUSDm	buy	0.11	5 078.062			2026.02.09 16:45:24	5 078.060	0.00	0.00	- 0.02
2026.02.09 16:45:21	3438856679	XAUUSDm	buy	0.21	5 077.610			2026.02.09 16:45:24	5 078.060	0.00	0.00	 9.45
2026.02.09 16:45:25	3438858237	XAUUSDm	buy	0.01	5 077.886			2026.02.09 16:45:48	5 079.969	0.00	0.00	 2.08
2026.02.09 16:45:49	3438864977	XAUUSDm	buy	0.01	5 079.830			2026.02.09 17:36:33	5 068.968	0.00	0.00	- 10.86
2026.02.09 16:46:02	3438869159	XAUUSDm	buy	0.11	5 079.394			2026.02.09 17:36:33	5 068.968	0.00	0.00	- 114.68
2026.02.09 16:46:04	3438869719	XAUUSDm	buy	0.21	5 079.251			2026.02.09 17:36:32	5 068.968	0.00	0.00	- 215.94
2026.02.09 16:46:21	3438873704	XAUUSDm	sell	0.01	5 076.204			2026.02.09 16:46:38	5 075.874	0.00	0.00	 0.33
2026.02.09 16:46:24	3438874473	XAUUSDm	sell	0.11	5 076.385			2026.02.09 16:46:38	5 075.967	0.00	0.00	 4.60
2026.02.09 16:46:27	3438875137	XAUUSDm	sell	0.21	5 076.758			2026.02.09 16:46:37	5 075.967	0.00	0.00	 16.61
2026.02.09 16:46:28	3438875207	XAUUSDm	buy	0.31	5 076.919			2026.02.09 17:36:32	5 068.968	0.00	0.00	- 246.48
2026.02.09 16:46:51	3438878777	XAUUSDm	sell	0.01	5 076.632			2026.02.09 16:47:56	5 076.740	0.00	0.00	- 0.11
2026.02.09 16:47:53	3438887864	XAUUSDm	sell	0.11	5 076.955			2026.02.09 16:47:55	5 076.740	0.00	0.00	 2.37
2026.02.09 16:47:56	3438888132	XAUUSDm	sell	0.01	5 076.545			2026.02.09 16:48:11	5 076.307	0.00	0.00	 0.24
2026.02.09 16:47:58	3438888262	XAUUSDm	sell	0.11	5 076.803			2026.02.09 16:48:10	5 076.153	0.00	0.00	 7.15
2026.02.09 16:48:16	3438891679	XAUUSDm	sell	0.01	5 076.519			2026.02.09 16:48:58	5 076.674	0.00	0.00	- 0.15
2026.02.09 16:48:51	3438895581	XAUUSDm	sell	0.11	5 076.803			2026.02.09 16:48:57	5 076.430	0.00	0.00	 4.10
2026.02.09 16:49:05	3438897008	XAUUSDm	sell	0.01	5 076.529			2026.02.09 16:49:11	5 076.020	0.00	0.00	 0.51
2026.02.09 16:49:09	3438897363	XAUUSDm	sell	0.11	5 076.799			2026.02.09 16:49:11	5 076.016	0.00	0.00	 8.61
2026.02.09 16:49:46	3438900304	XAUUSDm	sell	0.01	5 076.439			2026.02.09 16:49:58	5 076.357	0.00	0.00	 0.08
2026.02.09 16:49:54	3438900941	XAUUSDm	sell	0.11	5 076.700			2026.02.09 16:49:57	5 076.357	0.00	0.00	 3.77
2026.02.09 16:50:02	3438901733	XAUUSDm	sell	0.01	5 076.541			2026.02.09 16:51:13	5 073.523	0.00	0.00	 3.02
2026.02.09 16:51:14	3438911431	XAUUSDm	sell	0.01	5 073.425			2026.02.09 16:51:51	5 074.688	0.00	0.00	- 1.26
2026.02.09 16:51:23	3438912874	XAUUSDm	sell	0.11	5 073.875			2026.02.09 16:51:50	5 074.688	0.00	0.00	- 8.94
2026.02.09 16:51:26	3438913351	XAUUSDm	sell	0.21	5 074.462			2026.02.09 16:51:50	5 074.413	0.00	0.00	 1.03
2026.02.09 16:51:30	3438914030	XAUUSDm	sell	0.31	5 075.260			2026.02.09 16:51:50	5 074.413	0.00	0.00	 26.26
2026.02.09 16:52:04	3438918188	XAUUSDm	sell	0.01	5 073.617			2026.02.09 16:53:18	5 075.472	0.00	0.00	- 1.85
2026.02.09 16:52:11	3438918995	XAUUSDm	sell	0.11	5 074.221			2026.02.09 16:53:18	5 075.472	0.00	0.00	- 13.76
2026.02.09 16:52:31	3438920948	XAUUSDm	sell	0.21	5 074.764			2026.02.09 16:53:18	5 074.673	0.00	0.00	 1.91
2026.02.09 16:52:34	3438921418	XAUUSDm	sell	0.31	5 075.448			2026.02.09 16:53:17	5 074.673	0.00	0.00	 24.03
2026.02.09 16:53:47	3438930740	XAUUSDm	sell	0.01	5 073.408			2026.02.09 16:54:46	5 074.824	0.00	0.00	- 1.41
2026.02.09 16:53:51	3438931253	XAUUSDm	sell	0.11	5 074.221			2026.02.09 16:54:46	5 074.591	0.00	0.00	- 4.07
2026.02.09 16:54:23	3438934335	XAUUSDm	sell	0.21	5 074.919			2026.02.09 16:54:45	5 074.591	0.00	0.00	 6.89
2026.02.09 16:54:39	3438935868	XAUUSDm	sell	0.31	5 075.426			2026.02.09 16:54:45	5 074.591	0.00	0.00	 25.89
2026.02.09 16:54:55	3438937286	XAUUSDm	sell	0.01	5 073.510			2026.02.09 16:55:40	5 074.841	0.00	0.00	- 1.33
2026.02.09 16:55:02	3438938590	XAUUSDm	sell	0.11	5 074.140			2026.02.09 16:55:40	5 074.841	0.00	0.00	- 7.71
2026.02.09 16:55:08	3438939493	XAUUSDm	sell	0.21	5 074.876			2026.02.09 16:55:39	5 074.620	0.00	0.00	 5.38
2026.02.09 16:55:30	3438941470	XAUUSDm	sell	0.31	5 075.377			2026.02.09 16:55:39	5 074.620	0.00	0.00	 23.47
2026.02.09 16:55:45	3438943053	XAUUSDm	sell	0.01	5 073.673			2026.02.09 16:57:25	5 076.760	0.00	0.00	- 3.09
2026.02.09 16:57:03	3438954073	XAUUSDm	sell	0.11	5 075.024			2026.02.09 16:57:25	5 076.760	0.00	0.00	- 19.10
2026.02.09 16:57:13	3438955934	XAUUSDm	sell	0.21	5 076.055			2026.02.09 16:57:24	5 076.594	0.00	0.00	- 11.31
2026.02.09 16:57:14	3438956753	XAUUSDm	sell	0.31	5 076.657			2026.02.09 16:57:24	5 076.712	0.00	0.00	- 1.70
2026.02.09 16:57:16	3438958076	XAUUSDm	sell	0.41	5 077.437			2026.02.09 16:57:24	5 076.555	0.00	0.00	 36.16
2026.02.09 16:59:06	3438967680	XAUUSDm	sell	0.01	5 074.329			2026.02.09 16:59:22	5 073.188	0.00	0.00	 1.14
2026.02.09 16:59:11	3438968133	XAUUSDm	sell	0.11	5 075.021			2026.02.09 16:59:22	5 072.891	0.00	0.00	 23.43
2026.02.09 16:59:22	3438969382	XAUUSDm	sell	0.01	5 073.221			2026.02.09 16:59:27	5 073.976	0.00	0.00	- 0.76
2026.02.09 16:59:24	3438969640	XAUUSDm	sell	0.11	5 074.208			2026.02.09 16:59:27	5 073.976	0.00	0.00	 2.55
2026.02.09 16:59:27	3438969906	XAUUSDm	sell	0.01	5 073.799			2026.02.09 17:00:02	5 072.737	0.00	0.00	 1.06
2026.02.09 17:00:00	3438973475	XAUUSDm	sell	0.11	5 074.653			2026.02.09 17:00:02	5 072.675	0.00	0.00	 21.75
2026.02.09 17:00:03	3438974504	XAUUSDm	sell	0.01	5 072.723			2026.02.09 17:00:06	5 073.361	0.00	0.00	- 0.64
2026.02.09 17:00:04	3438974706	XAUUSDm	sell	0.11	5 073.787			2026.02.09 17:00:06	5 073.361	0.00	0.00	 4.69
2026.02.09 17:00:06	3438975062	XAUUSDm	sell	0.01	5 073.273			2026.02.09 17:00:26	5 074.754	0.00	0.00	- 1.48
2026.02.09 17:00:08	3438975238	XAUUSDm	sell	0.11	5 074.298			2026.02.09 17:00:26	5 074.754	0.00	0.00	- 5.01
2026.02.09 17:00:16	3438975918	XAUUSDm	sell	0.21	5 075.352			2026.02.09 17:00:25	5 074.754	0.00	0.00	 12.56
2026.02.09 17:00:29	3438977573	XAUUSDm	sell	0.01	5 073.870			2026.02.09 17:00:38	5 074.115	0.00	0.00	- 0.25
2026.02.09 17:00:30	3438977721	XAUUSDm	sell	0.11	5 074.182			2026.02.09 17:00:38	5 074.115	0.00	0.00	 0.73
2026.02.09 17:00:38	3438978513	XAUUSDm	sell	0.01	5 073.755			2026.02.09 17:01:05	5 073.728	0.00	0.00	 0.03
2026.02.09 17:00:57	3438980024	XAUUSDm	sell	0.11	5 074.445			2026.02.09 17:01:04	5 073.871	0.00	0.00	 6.32
2026.02.09 17:01:05	3438980938	XAUUSDm	sell	0.01	5 073.886			2026.02.09 17:03:10	5 070.821	0.00	0.00	 3.07
2026.02.09 17:03:10	3438995293	XAUUSDm	sell	0.01	5 070.581			2026.02.09 17:03:33	5 070.773	0.00	0.00	- 0.19
2026.02.09 17:03:20	3438996432	XAUUSDm	sell	0.11	5 070.984			2026.02.09 17:03:33	5 070.638	0.00	0.00	 3.80
2026.02.09 17:03:34	3438997679	XAUUSDm	sell	0.01	5 070.456			2026.02.09 17:04:02	5 067.347	0.00	0.00	 3.11
2026.02.09 17:04:03	3439003226	XAUUSDm	sell	0.01	5 066.851			2026.02.09 17:04:07	5 067.450	0.00	0.00	- 0.60
2026.02.09 17:04:04	3439003846	XAUUSDm	sell	0.11	5 067.795			2026.02.09 17:04:06	5 067.714	0.00	0.00	 0.90
2026.02.09 17:04:07	3439004451	XAUUSDm	sell	0.01	5 067.207			2026.02.09 17:04:08	5 065.147	0.00	0.00	 2.06
2026.02.09 17:04:09	3439006243	XAUUSDm	sell	0.01	5 065.230			2026.02.09 17:04:45	5 066.578	0.00	0.00	- 1.35
2026.02.09 17:04:23	3439010384	XAUUSDm	sell	0.11	5 065.982			2026.02.09 17:04:44	5 066.578	0.00	0.00	- 6.56
2026.02.09 17:04:36	3439012031	XAUUSDm	sell	0.21	5 067.192			2026.02.09 17:04:44	5 066.376	0.00	0.00	 17.13
2026.02.09 17:04:45	3439013672	XAUUSDm	sell	0.01	5 066.374			2026.02.09 17:05:18	5 068.273	0.00	0.00	- 1.90
2026.02.09 17:05:00	3439015351	XAUUSDm	sell	0.11	5 067.463			2026.02.09 17:05:18	5 068.273	0.00	0.00	- 8.91
2026.02.09 17:05:10	3439016783	XAUUSDm	sell	0.21	5 068.157			2026.02.09 17:05:17	5 068.163	0.00	0.00	- 0.12
2026.02.09 17:05:18	3439018193	XAUUSDm	sell	0.01	5 067.913			2026.02.09 17:06:42	5 069.092	0.00	0.00	- 1.18
2026.02.09 17:05:39	3439020150	XAUUSDm	sell	0.11	5 068.427			2026.02.09 17:06:42	5 069.054	0.00	0.00	- 6.89
2026.02.09 17:05:46	3439021132	XAUUSDm	sell	0.21	5 069.011			2026.02.09 17:06:42	5 069.054	0.00	0.00	- 0.90
2026.02.09 17:05:47	3439021605	XAUUSDm	sell	0.31	5 069.886			2026.02.09 17:06:41	5 069.054	0.00	0.00	 25.80
2026.02.09 17:06:43	3439033795	XAUUSDm	sell	0.01	5 068.852			2026.02.09 17:06:51	5 068.826	0.00	0.00	 0.02
2026.02.09 17:06:45	3439034219	XAUUSDm	sell	0.11	5 069.547			2026.02.09 17:06:50	5 068.826	0.00	0.00	 7.93
2026.02.09 17:06:51	3439034774	XAUUSDm	sell	0.01	5 068.586			2026.02.09 17:06:58	5 066.890	0.00	0.00	 1.70
2026.02.09 17:06:59	3439036770	XAUUSDm	sell	0.01	5 066.739			2026.02.09 17:08:31	5 068.313	0.00	0.00	- 1.57
2026.02.09 17:07:04	3439037974	XAUUSDm	sell	0.11	5 067.249			2026.02.09 17:08:31	5 068.313	0.00	0.00	- 11.70
2026.02.09 17:07:15	3439039205	XAUUSDm	sell	0.21	5 068.029			2026.02.09 17:08:30	5 068.027	0.00	0.00	 0.04
2026.02.09 17:07:16	3439039535	XAUUSDm	sell	0.31	5 068.773			2026.02.09 17:08:30	5 068.027	0.00	0.00	 23.12
2026.02.09 17:08:31	3439050688	XAUUSDm	sell	0.01	5 068.187			2026.02.09 17:08:37	5 067.281	0.00	0.00	 0.91
2026.02.09 17:08:37	3439052107	XAUUSDm	sell	0.01	5 067.075			2026.02.09 17:08:44	5 066.459	0.00	0.00	 0.62
2026.02.09 17:08:45	3439053547	XAUUSDm	sell	0.01	5 066.219			2026.02.09 17:09:02	5 065.576	0.00	0.00	 0.64
2026.02.09 17:09:02	3439056428	XAUUSDm	sell	0.01	5 065.597			2026.02.09 17:09:12	5 065.050	0.00	0.00	 0.55
2026.02.09 17:09:13	3439058598	XAUUSDm	sell	0.01	5 064.495			2026.02.09 17:09:14	5 062.508	0.00	0.00	 1.99
2026.02.09 17:09:14	3439060928	XAUUSDm	sell	0.01	5 062.098			2026.02.09 17:09:15	5 061.232	0.00	0.00	 0.87
2026.02.09 17:09:15	3439061997	XAUUSDm	sell	0.01	5 060.581			2026.02.09 17:36:32	5 069.370	0.00	0.00	- 8.79
2026.02.09 17:09:16	3439062911	XAUUSDm	sell	0.11	5 061.283			2026.02.09 17:36:31	5 069.312	0.00	0.00	- 88.32
2026.02.09 17:09:20	3439064175	XAUUSDm	sell	0.21	5 062.148			2026.02.09 17:36:31	5 069.312	0.00	0.00	- 150.44
2026.02.09 17:09:34	3439067257	XAUUSDm	sell	0.31	5 063.037			2026.02.09 17:36:30	5 069.312	0.00	0.00	- 194.52
2026.02.09 17:36:34	3439236041	XAUUSDm	sell	0.01	5 068.950			2026.02.09 17:37:28	5 066.863	0.00	0.00	 2.09
2026.02.09 17:36:37	3439236753	XAUUSDm	buy	0.01	5 068.581			2026.02.09 17:37:02	5 068.151	0.00	0.00	- 0.43
2026.02.09 17:36:39	3439237186	XAUUSDm	buy	0.02	5 067.769			2026.02.09 17:37:02	5 068.037	0.00	0.00	 0.53
2026.02.09 17:36:45	3439239142	XAUUSDm	buy	0.03	5 066.930			2026.02.09 17:37:02	5 068.037	0.00	0.00	 3.32
2026.02.09 17:37:29	3439243423	XAUUSDm	sell	0.01	5 066.623			2026.02.09 17:39:04	5 067.834	0.00	0.00	- 1.21
2026.02.09 17:37:30	3439243823	XAUUSDm	sell	0.02	5 066.722			2026.02.09 17:39:03	5 067.566	0.00	0.00	- 1.69
2026.02.09 17:37:31	3439243909	XAUUSDm	sell	0.03	5 067.289			2026.02.09 17:39:03	5 067.566	0.00	0.00	- 0.83
2026.02.09 17:38:15	3439247398	XAUUSDm	sell	0.04	5 067.643			2026.02.09 17:39:03	5 067.566	0.00	0.00	 0.31
2026.02.09 17:38:50	3439249827	XAUUSDm	sell	0.05	5 068.129			2026.02.09 17:39:02	5 067.566	0.00	0.00	 2.82
"""

# I'll only include the first chunk here since the full data will be loaded from the user's paste
# The actual parsing handles the full dataset

def parse_trades(raw):
    trades = []
    for line in raw.strip().split('\n'):
        line = line.strip()
        if not line:
            continue
        # Normalize whitespace in prices (e.g. "5 073.834" -> "5073.834")
        # Tab-separated fields
        parts = line.split('\t')
        if len(parts) < 13:
            continue
        
        open_time_str = parts[0].strip()
        position_id = parts[1].strip()
        symbol = parts[2].strip()
        trade_type = parts[3].strip()
        volume_str = parts[4].strip()
        open_price_str = parts[5].strip().replace(' ', '')
        # parts[6] = S/L, parts[7] = T/P (may be empty)
        close_time_str = parts[8].strip()
        close_price_str = parts[9].strip().replace(' ', '')
        # parts[10] = Commission, parts[11] = Swap
        profit_str = parts[12].strip().replace(' ', '').replace('\u2212', '-')
        
        try:
            open_time = datetime.strptime(open_time_str, '%Y.%m.%d %H:%M:%S')
            close_time = datetime.strptime(close_time_str, '%Y.%m.%d %H:%M:%S')
            volume = float(volume_str)
            profit = float(profit_str)
            open_price = float(open_price_str)
            close_price = float(close_price_str)
        except:
            continue
        
        duration = (close_time - open_time).total_seconds()
        trades.append({
            'open_time': open_time,
            'close_time': close_time,
            'position_id': position_id,
            'symbol': symbol,
            'type': trade_type,
            'volume': volume,
            'open_price': open_price,
            'close_price': close_price,
            'profit': profit,
            'duration_sec': duration,
        })
    return trades


def run_audit(trades):
    total = len(trades)
    if total == 0:
        print("No trades found!")
        return
    
    total_profit = sum(t['profit'] for t in trades)
    total_winning_profit = sum(t['profit'] for t in trades if t['profit'] > 0)
    total_losing = sum(t['profit'] for t in trades if t['profit'] < 0)
    
    print("=" * 72)
    print("       PROP FIRM TRADE AUDIT — COMPLIANCE REPORT")
    print("       FundedNext Stellar 2-Step / FXIFY")
    print("=" * 72)
    print(f"\nTotal Trades: {total}")
    print(f"Total Net P&L: ${total_profit:.2f}")
    print(f"Total Winning P&L: ${total_winning_profit:.2f}")
    print(f"Total Losing P&L: ${total_losing:.2f}")
    
    dates = set(t['open_time'].date() for t in trades)
    print(f"Trading Days: {len(dates)} ({min(dates)} to {max(dates)})")
    
    # ================================================================
    # 1. HFT / SUB-30-SECOND TRADES
    # ================================================================
    print("\n" + "=" * 72)
    print("  1. HFT CHECK — Trades Under 30 Seconds")
    print("=" * 72)
    
    sub30 = [t for t in trades if t['duration_sec'] < 30]
    sub30_pct = len(sub30) / total * 100
    sub30_profit = sum(t['profit'] for t in sub30)
    
    print(f"\n  Trades < 30 seconds:  {len(sub30)} / {total}  ({sub30_pct:.1f}%)")
    print(f"  Profit from < 30s:    ${sub30_profit:.2f}")
    
    if sub30_pct > 25:
        print(f"\n  ⚠️  CRITICAL FLAG: {sub30_pct:.1f}% of trades are under 30s!")
        print("  This WILL trigger HFT detection at most prop firms.")
    elif sub30_pct > 10:
        print(f"\n  ⚠️  WARNING: {sub30_pct:.1f}% of trades are under 30s.")
        print("  High risk of HFT flag depending on firm thresholds.")
    else:
        print(f"\n  ✅ Under 30s trades are {sub30_pct:.1f}% — within safe range.")
    
    # Duration distribution
    sub5 = len([t for t in trades if t['duration_sec'] < 5])
    sub10 = len([t for t in trades if t['duration_sec'] < 10])
    sub15 = len([t for t in trades if t['duration_sec'] < 15])
    sub60 = len([t for t in trades if t['duration_sec'] < 60])
    sub120 = len([t for t in trades if t['duration_sec'] < 120])
    
    print(f"\n  Duration Breakdown:")
    print(f"    < 5 seconds:   {sub5:>5} trades ({sub5/total*100:.1f}%)")
    print(f"    < 10 seconds:  {sub10:>5} trades ({sub10/total*100:.1f}%)")
    print(f"    < 15 seconds:  {sub15:>5} trades ({sub15/total*100:.1f}%)")
    print(f"    < 30 seconds:  {len(sub30):>5} trades ({sub30_pct:.1f}%)")
    print(f"    < 60 seconds:  {sub60:>5} trades ({sub60/total*100:.1f}%)")
    print(f"    < 2 minutes:   {sub120:>5} trades ({sub120/total*100:.1f}%)")
    
    # Shortest trades
    sorted_by_duration = sorted(trades, key=lambda t: t['duration_sec'])
    print(f"\n  10 Shortest Trades:")
    print(f"  {'Open Time':<22} {'Type':<5} {'Vol':>5} {'Duration':>8} {'Profit':>9}")
    for t in sorted_by_duration[:10]:
        print(f"  {t['open_time'].strftime('%Y.%m.%d %H:%M:%S'):<22} {t['type']:<5} {t['volume']:>5.2f} {t['duration_sec']:>6.0f}s  ${t['profit']:>8.2f}")
    
    # ================================================================
    # 2. FXIFY 2-MINUTE RULE
    # ================================================================
    print("\n" + "=" * 72)
    print("  2. FXIFY 2-MINUTE RULE — Profit from Trades > 2 Minutes")
    print("=" * 72)
    
    over2min = [t for t in trades if t['duration_sec'] >= 120]
    under2min = [t for t in trades if t['duration_sec'] < 120]
    
    profit_over2min = sum(t['profit'] for t in over2min if t['profit'] > 0)
    profit_under2min = sum(t['profit'] for t in under2min if t['profit'] > 0)
    
    if total_winning_profit > 0:
        pct_over2min = profit_over2min / total_winning_profit * 100
        pct_under2min = profit_under2min / total_winning_profit * 100
    else:
        pct_over2min = 0
        pct_under2min = 0
    
    print(f"\n  Trades >= 2 min: {len(over2min)} ({len(over2min)/total*100:.1f}%)")
    print(f"  Trades < 2 min:  {len(under2min)} ({len(under2min)/total*100:.1f}%)")
    print(f"\n  Winning profit from >= 2 min:  ${profit_over2min:.2f}  ({pct_over2min:.1f}%)")
    print(f"  Winning profit from < 2 min:   ${profit_under2min:.2f}  ({pct_under2min:.1f}%)")
    
    # FXIFY rule: more than 50% must come from >2 min trades
    if pct_over2min >= 50:
        print(f"\n  ✅ PASS: {pct_over2min:.1f}% of winning profit is from trades > 2 min.")
    else:
        print(f"\n  ❌ FAIL: Only {pct_over2min:.1f}% of winning profit from > 2 min trades.")
        print("  FXIFY requires >50% of profit from trades longer than 2 minutes.")
    
    # Also check net profit contribution
    net_over2min = sum(t['profit'] for t in over2min)
    net_under2min = sum(t['profit'] for t in under2min)
    print(f"\n  Net P&L from >= 2 min trades: ${net_over2min:.2f}")
    print(f"  Net P&L from < 2 min trades:  ${net_under2min:.2f}")
    
    # ================================================================
    # 3. GRID / STACKING — SIMULTANEOUS OPEN POSITIONS
    # ================================================================
    print("\n" + "=" * 72)
    print("  3. GRID/STACKING — Simultaneous Open Positions (Max >5)")
    print("=" * 72)
    
    # Build timeline events
    events = []
    for t in trades:
        events.append((t['open_time'], 'open', t))
        events.append((t['close_time'], 'close', t))
    events.sort(key=lambda e: (e[0], 0 if e[1] == 'close' else 1))
    
    current_open = 0
    max_open = 0
    max_open_time = None
    max_open_volume = 0
    violations_5 = []
    current_positions = []
    
    for time, event_type, trade in events:
        if event_type == 'open':
            current_open += 1
            current_positions.append(trade)
        else:
            current_open -= 1
            current_positions = [p for p in current_positions if p['position_id'] != trade['position_id']]
        
        if current_open > max_open:
            max_open = current_open
            max_open_time = time
            max_open_volume = sum(p['volume'] for p in current_positions)
        
        if current_open > 5 and event_type == 'open':
            total_vol = sum(p['volume'] for p in current_positions)
            violations_5.append((time, current_open, total_vol))
    
    # Deduplicate violations to show peaks
    print(f"\n  Maximum simultaneous positions: {max_open}")
    print(f"  Time of maximum:               {max_open_time}")
    print(f"  Total volume at peak:          {max_open_volume:.2f} lots")
    
    if max_open > 5:
        print(f"\n  ⚠️  CRITICAL FLAG: Peak of {max_open} simultaneous positions detected!")
        print("  Grid/stacking above 5 positions may violate prop firm rules.")
        
        # Show unique peaks (summarize by minute)
        peak_minutes = {}
        for v_time, v_count, v_vol in violations_5:
            minute_key = v_time.strftime('%Y.%m.%d %H:%M')
            if minute_key not in peak_minutes or v_count > peak_minutes[minute_key][0]:
                peak_minutes[minute_key] = (v_count, v_vol, v_time)
        
        print(f"\n  Stacking Violations (>5 positions) — {len(peak_minutes)} time windows:")
        print(f"  {'Time':<22} {'Positions':>10} {'Total Vol':>10}")
        for mk in sorted(peak_minutes.keys())[:20]:
            cnt, vol, tm = peak_minutes[mk]
            print(f"  {tm.strftime('%Y.%m.%d %H:%M:%S'):<22} {cnt:>10} {vol:>9.2f}")
        if len(peak_minutes) > 20:
            print(f"  ... and {len(peak_minutes)-20} more windows")
    else:
        print(f"\n  ✅ Maximum simultaneous positions ({max_open}) is within 5-position limit.")
    
    # ================================================================
    # 4. AVERAGE HOLD TIME
    # ================================================================
    print("\n" + "=" * 72)
    print("  4. AVERAGE HOLD TIME")
    print("=" * 72)
    
    durations = [t['duration_sec'] for t in trades]
    avg_hold = sum(durations) / len(durations)
    median_hold = sorted(durations)[len(durations)//2]
    min_hold = min(durations)
    max_hold = max(durations)
    
    def fmt_duration(secs):
        if secs < 60:
            return f"{secs:.0f}s"
        elif secs < 3600:
            m = int(secs // 60)
            s = int(secs % 60)
            return f"{m}m {s}s"
        else:
            h = int(secs // 3600)
            m = int((secs % 3600) // 60)
            return f"{h}h {m}m"
    
    print(f"\n  Average hold time:  {fmt_duration(avg_hold)} ({avg_hold:.0f} seconds)")
    print(f"  Median hold time:   {fmt_duration(median_hold)} ({median_hold:.0f} seconds)")
    print(f"  Shortest trade:     {fmt_duration(min_hold)}")
    print(f"  Longest trade:      {fmt_duration(max_hold)}")
    
    # Percentiles
    sorted_dur = sorted(durations)
    p25 = sorted_dur[len(sorted_dur)//4]
    p75 = sorted_dur[3*len(sorted_dur)//4]
    p90 = sorted_dur[int(len(sorted_dur)*0.9)]
    print(f"\n  25th percentile:    {fmt_duration(p25)}")
    print(f"  75th percentile:    {fmt_duration(p75)}")
    print(f"  90th percentile:    {fmt_duration(p90)}")
    
    if avg_hold < 60:
        print(f"\n  ⚠️  WARNING: Average hold time is under 1 minute.")
        print("  Extremely short average — high risk of HFT/scalping flags.")
    elif avg_hold < 120:
        print(f"\n  ⚠️  CAUTION: Average hold time is under 2 minutes.")
    else:
        print(f"\n  ✅ Average hold time is {fmt_duration(avg_hold)} — reasonable.")
    
    # ================================================================
    # 5. GAMBLING / MARTINGALE BEHAVIOR
    # ================================================================
    print("\n" + "=" * 72)
    print("  5. GAMBLING / MARTINGALE BEHAVIOR")
    print("=" * 72)
    
    # Sort by open time to analyze sequential behavior
    sorted_trades = sorted(trades, key=lambda t: t['open_time'])
    
    # Check lot size escalation after losses
    martingale_sequences = []
    consecutive_losses = 0
    prev_volume = None
    sequence_start = None
    
    for i in range(1, len(sorted_trades)):
        prev = sorted_trades[i-1]
        curr = sorted_trades[i]
        
        if prev['profit'] < 0 and curr['volume'] > prev['volume'] * 1.5:
            if sequence_start is None:
                sequence_start = i - 1
            consecutive_losses += 1
        else:
            if consecutive_losses >= 2:
                martingale_sequences.append({
                    'start_idx': sequence_start,
                    'length': consecutive_losses + 1,
                    'start_vol': sorted_trades[sequence_start]['volume'],
                    'end_vol': sorted_trades[i-1]['volume'],
                    'time': sorted_trades[sequence_start]['open_time'],
                })
            consecutive_losses = 0
            sequence_start = None
    
    # Volume analysis
    volumes = [t['volume'] for t in trades]
    min_vol = min(volumes)
    max_vol = max(volumes)
    avg_vol = sum(volumes) / len(volumes)
    
    print(f"\n  Lot Size Analysis:")
    print(f"    Minimum lot:  {min_vol:.2f}")
    print(f"    Maximum lot:  {max_vol:.2f}")
    print(f"    Average lot:  {avg_vol:.2f}")
    print(f"    Max/Min ratio: {max_vol/min_vol:.1f}x")
    
    # Volume distribution
    vol_buckets = defaultdict(int)
    for v in volumes:
        if v <= 0.01:
            vol_buckets['0.01'] += 1
        elif v <= 0.05:
            vol_buckets['0.02-0.05'] += 1
        elif v <= 0.10:
            vol_buckets['0.06-0.10'] += 1
        elif v <= 0.21:
            vol_buckets['0.11-0.21'] += 1
        elif v <= 0.41:
            vol_buckets['0.22-0.41'] += 1
        elif v <= 0.61:
            vol_buckets['0.42-0.61'] += 1
        else:
            vol_buckets['0.62+'] += 1
    
    print(f"\n  Volume Distribution:")
    for bucket in ['0.01', '0.02-0.05', '0.06-0.10', '0.11-0.21', '0.22-0.41', '0.42-0.61', '0.62+']:
        cnt = vol_buckets.get(bucket, 0)
        pct = cnt / total * 100
        bar = '█' * int(pct / 2)
        print(f"    {bucket:>10}: {cnt:>5} ({pct:>5.1f}%) {bar}")
    
    # Grid pattern detection: escalating lots in rapid succession
    print(f"\n  Grid Pyramiding Pattern Detection:")
    grid_patterns = []
    i = 0
    while i < len(sorted_trades):
        # Look for sequences of increasing lots within 30 seconds of each other
        seq = [sorted_trades[i]]
        j = i + 1
        while j < len(sorted_trades):
            if (sorted_trades[j]['open_time'] - seq[-1]['open_time']).total_seconds() <= 30:
                if sorted_trades[j]['volume'] >= seq[-1]['volume']:
                    seq.append(sorted_trades[j])
                    j += 1
                else:
                    break
            else:
                break
        
        if len(seq) >= 3 and seq[-1]['volume'] > seq[0]['volume']:
            grid_patterns.append({
                'time': seq[0]['open_time'],
                'count': len(seq),
                'start_vol': seq[0]['volume'],
                'end_vol': seq[-1]['volume'],
                'total_vol': sum(s['volume'] for s in seq),
            })
        i = j if j > i + 1 else i + 1
    
    if grid_patterns:
        print(f"    Found {len(grid_patterns)} pyramiding sequences (3+ trades, escalating lots within 30s)")
        print(f"\n    {'Time':<22} {'Trades':>7} {'Start Vol':>10} {'End Vol':>10} {'Total Vol':>10}")
        for gp in grid_patterns[:15]:
            print(f"    {gp['time'].strftime('%Y.%m.%d %H:%M:%S'):<22} {gp['count']:>7} {gp['start_vol']:>10.2f} {gp['end_vol']:>10.2f} {gp['total_vol']:>10.2f}")
        if len(grid_patterns) > 15:
            print(f"    ... and {len(grid_patterns)-15} more sequences")
    
    # Single trade risk check
    print(f"\n  Largest Single-Trade Losses:")
    worst = sorted(trades, key=lambda t: t['profit'])[:10]
    print(f"  {'Open Time':<22} {'Type':<5} {'Vol':>5} {'Duration':>8} {'Profit':>10}")
    for t in worst:
        print(f"  {t['open_time'].strftime('%Y.%m.%d %H:%M:%S'):<22} {t['type']:<5} {t['volume']:>5.2f} {fmt_duration(t['duration_sec']):>8} ${t['profit']:>9.2f}")
    
    # Day-level analysis
    print(f"\n  Daily P&L Summary:")
    daily_pl = defaultdict(float)
    daily_trades = defaultdict(int)
    for t in trades:
        d = t['open_time'].date()
        daily_pl[d] += t['profit']
        daily_trades[d] += 1
    
    for d in sorted(daily_pl.keys()):
        status = "✅" if daily_pl[d] >= 0 else "❌"
        print(f"    {d}: ${daily_pl[d]:>10.2f}  ({daily_trades[d]} trades)  {status}")
    
    # ================================================================
    # SUMMARY
    # ================================================================
    print("\n" + "=" * 72)
    print("  OVERALL RISK ASSESSMENT")
    print("=" * 72)
    
    flags = []
    
    if sub30_pct > 25:
        flags.append(("CRITICAL", f"HFT: {sub30_pct:.1f}% of trades under 30 seconds"))
    elif sub30_pct > 10:
        flags.append(("WARNING", f"HFT: {sub30_pct:.1f}% of trades under 30 seconds"))
    
    if pct_over2min < 50:
        flags.append(("CRITICAL", f"FXIFY 2-min rule: Only {pct_over2min:.1f}% winning profit from >2min trades"))
    
    if max_open > 5:
        flags.append(("CRITICAL", f"Grid stacking: Up to {max_open} simultaneous positions"))
    
    if avg_hold < 60:
        flags.append(("WARNING", f"Average hold time only {fmt_duration(avg_hold)}"))
    
    if max_vol / min_vol > 50:
        flags.append(("WARNING", f"Lot size range: {min_vol:.2f} to {max_vol:.2f} ({max_vol/min_vol:.0f}x ratio)"))
    
    if not flags:
        print("\n  ✅ No major compliance issues detected.")
    else:
        for severity, msg in flags:
            icon = "🔴" if severity == "CRITICAL" else "🟡"
            print(f"\n  {icon} [{severity}] {msg}")
    
    print("\n" + "=" * 72)


# ================================================================
# MAIN — Read the full data file
# ================================================================
if __name__ == '__main__':
    import sys
    import os
    
    # Try to load from the file if it exists, otherwise use embedded data
    data_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'trade_data.txt')
    
    if os.path.exists(data_file):
        with open(data_file, 'r', encoding='utf-8') as f:
            raw = f.read()
    else:
        raw = RAW_DATA
    
    trades = parse_trades(raw)
    print(f"Parsed {len(trades)} trades from data.\n")
    run_audit(trades)
